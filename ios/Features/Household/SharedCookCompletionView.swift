import HouseholdClient
import SwiftUI

func cookingText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "SharedCooking")
}
private struct ActualUse: Identifiable {
    let id = UUID()
    var needID: UUID
    var mode = ""
    var lotID: UUID?
    var amount = ""
    var unit = ""
}
private struct CookedOutput: Identifiable {
    let id = UUID()
    var name = ""
    var portions = 1
    var location = "fridge"
    var allocations: [UUID: Int] = [:]
    var includeUseFirst = false
    var useFirstAt = Date()
}

struct SharedCookCompletionView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    @EnvironmentObject private var membership: MembershipCoordinator
    let shopID, occurrence: UUID
    @State private var review: SharedCookReview?
    @State private var rows: [ActualUse] = []
    @State private var outputs: [CookedOutput] = []
    @State private var servings = 1
    @State private var failed = false
    @State private var resolution: SharedCookReview.Unresolved?
    @State private var resolveLot: UUID?
    @State private var resolveAmount = ""
    @State private var included = false
    @State private var confirmUndo = false

    private var paid: Bool {
        guard let seat = membership.model, seat.context?.householdID == model.householdID,
              seat.context?.purchaserID == model.memberID else { return false }
        return seat.hasPaidAccess
    }
    private var outputPortions: Int { outputs.reduce(0) { $0 + $1.portions } }
    private var allowed: Bool {
        !household.locked && household.sharedShop === model && model.canCompleteCook &&
            model.scope.shopId.flatMap(UUID.init(uuidString:)) == shopID
    }
    var body: some View {
        WorkingForm {
            if allowed, model.pendingSharedCook, model.delivery == .waiting {
                Button(cookingText("Retry saved cooking change")) { Task { await model.retry(); await load() } }
                    .disabled(model.busy)
            }
            if allowed, let review {
                Section { Text(verbatim: review.title).font(.headline) }
                if let completion = review.completion {
                    Section(cookingText("Cooking completed")) {
                        LabeledContent(cookingText("Actual servings"), value: completion.servings.formatted())
                        if completion.unresolved.isEmpty { Text(cookingText("Inventory updated")) }
                        else { Text(cookingText("Inventory needs review")) }
                        ForEach(completion.unresolved) { row in
                            if let need = review.needs.first(where: { $0.id == row.needId }) {
                                Button { resolution = row; resolveLot = row.lotId; resolveAmount = ""; included = false } label: {
                                    Label(([need.name] + need.groupNames).joined(separator: " · "), systemImage: "pencil")
                                }
                            }
                        }
                        if model.canReadPantry {
                            NavigationLink(ht("Pantry and freezer")) {
                                SharedPantryView(model: model, household: household, shopID: shopID)
                            }
                        }
                        if model.canShareMealFeedback {
                            NavigationLink(cookingText("Household meal feedback")) {
                                SharedCookFeedbackView(model: model, occurrence: occurrence, cook: completion.cookId)
                            }.accessibilityIdentifier("sharedCook.mealFeedback")
                        }
                        Button(cookingText("Undo cooking changes"), role: .destructive) { confirmUndo = true }
                    }
                } else {
                    Stepper(value: $servings, in: 1...1000) {
                        LabeledContent(cookingText("Actual servings"), value: servings.formatted())
                    }
                    ForEach(review.needs) { need in ingredient(need) }
                    Section(cookingText("Counted leftovers")) {
                        ForEach($outputs) { $output in
                            TextField(cookingText("Food name"), text: $output.name)
                            Stepper(value: $output.portions, in: 1...1000) {
                                LabeledContent(cookingText("Portions"), value: output.portions.formatted())
                            }
                            Picker(cookingText("Location"), selection: $output.location) {
                                ForEach(["fridge","freezer","pantry"], id: \.self) { Text(cookingText($0)).tag($0) }
                            }
                            Toggle(cookingText("Set a use-first date"), isOn: $output.includeUseFirst)
                            if output.includeUseFirst {
                                DatePicker(ht("Use first by"), selection: $output.useFirstAt, displayedComponents: .date)
                            }
                            if paid, let targets = review.portionTargets, !targets.isEmpty {
                                allocationControls($output, targets: targets)
                            } else if !output.allocations.isEmpty {
                                Button(cookingText("Remove portion reservations")) { output.allocations = [:] }
                            }
                            Button(cookingText("Remove output"), role: .destructive) { outputs.removeAll { $0.id == output.id } }
                        }
                        if outputPortions > servings {
                            Text(cookingText("Counted leftovers exceed the actual servings.")).foregroundStyle(Theme.error)
                        } else if !outputs.isEmpty {
                            LabeledContent(cookingText("Servings outside these batches"), value: (servings - outputPortions).formatted())
                        }
                        Button(cookingText("Add counted leftovers")) { outputs.append(CookedOutput()) }.disabled(outputs.count >= 12)
                    }
                    Button(cookingText("Save actual cooking")) { Task { await save(review) } }
                        .disabled(commandUses(review) == nil || !validAllocations(review) || !outputs.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            } else if failed || !allowed {
                Text(cookingText("Refresh the meal and stock to continue."))
            } else { ProgressView() }
            if allowed {
                Button(cookingText("Refresh")) { Task { await load() } }
                if let notice = model.notice { Text(verbatim: notice) }
            }
        }
        .disabled(model.busy)
        .navigationTitle(cookingText("Record cooking"))
        .task(id: allowed) { await load() }
        .confirmationDialog(cookingText("Undo cooking changes?"), isPresented: $confirmUndo) {
            if let review, let done = review.completion {
                Button(cookingText("Undo cooking changes"), role: .destructive) {
                    Task { await submit("cook.undo", ["cookId": idValue(done.cookId)], review) }
                }
            }
        }
        .sheet(item: $resolution) { row in
            if allowed, let review, let done = review.completion, let need = review.needs.first(where: { $0.id == row.needId }) {
                NavigationStack {
                    WorkingForm {
                        Text(verbatim: need.name)
                        Picker(cookingText("Used from"), selection: $resolveLot) {
                            Text(cookingText("Choose a lot")).tag(nil as UUID?)
                            ForEach(need.lots.filter { row.lotId == nil || $0.id == row.lotId }) { lot in
                                Text(verbatim: lotLabel(lot, among: need.lots)).tag(Optional(lot.id))
                            }
                        }
                        if let lot = need.lots.first(where: { $0.id == resolveLot }) {
                            let unit = lot.quantity?.unit ?? need.quantity?.unit
                            TextField(cookingText("Actual amount, such as 1/2"), text: $resolveAmount)
                            if let unit { Text(cookingText(unit)) }
                            Toggle(cookingText("A later physical count already includes this use"), isOn: $included)
                            Button(cookingText("Resolve use")) {
                                guard let unit, let q = quantity(resolveAmount, unit: unit) else { return }
                                resolution = nil
                                Task { await submit("cook.resolve", ["cookId": idValue(done.cookId), "rowId": idValue(row.id),
                                    "lotId": idValue(lot.id), "headId": idValue(lot.headId), "quantity": q, "includedInCount": .bool(included)], review) }
                            }.disabled(unit.flatMap { quantity(resolveAmount, unit: $0) } == nil)
                        }
                    }.navigationTitle(cookingText("Resolve use"))
                    .toolbar { Button(cookingText("Close")) { resolution = nil } }
                }
            }
        }
    }
    private func validAllocations(_ review: SharedCookReview) -> Bool {
        guard outputPortions <= servings else { return false }
        var totals: [UUID: Int] = [:]
        for out in outputs {
            guard out.allocations.values.reduce(0, +) <= out.portions else { return false }
            for (id, portions) in out.allocations {
                totals[id, default: 0] += portions
                guard paid, portions > 0, let target = review.portionTargets?.first(where: { $0.id == id }),
                      totals[id, default: 0] <= target.limit else { return false }
            }
        }
        return true
    }

    private func allocationControls(_ batch: Binding<CookedOutput>, targets: [SharedCookReview.PortionTarget]) -> some View {
        let output = batch.wrappedValue
        let unassigned = output.portions - output.allocations.values.reduce(0, +)
        return DisclosureGroup(cookingText("Reserve portions for people and days")) {
            LabeledContent(cookingText("Unassigned portions"), value: unassigned.formatted())
            ForEach(targets) { target in
                let assigned = output.allocations[target.id] ?? 0
                let inOtherBatches = outputs.filter { $0.id != output.id }.reduce(0) { $0 + ($1.allocations[target.id] ?? 0) }
                let limit = max(assigned, min(assigned + unassigned, target.limit - inOtherBatches))
                let amount = Binding<Int>(get: { batch.wrappedValue.allocations[target.id] ?? 0 }, set: { value in
                    batch.wrappedValue.allocations[target.id] = value > 0 ? value : nil
                })
                Stepper(value: amount, in: 0...max(0, limit)) {
                    VStack(alignment: .leading) {
                        Text(verbatim: target.title + " · " + sharedMealScheduleText(target.day))
                        Text(verbatim: [target.group, target.ingredient, assigned.formatted()].joined(separator: " · "))
                    }
                }
            }
        }
    }

    @ViewBuilder private func ingredient(_ need: SharedCookReview.Need) -> some View {
        Section {
            ForEach($rows) { $row in
                if row.needID == need.id {
                    Picker(cookingText("Actual use"), selection: $row.mode) {
                        Text(cookingText("Choose actual use")).tag("")
                        Text(cookingText("Known amount")).tag("known")
                        Text(cookingText("Used, quantity or source not tracked")).tag("unknown")
                        Text(cookingText("Not used")).tag("notUsed")
                    }
                    if row.mode == "known" || row.mode == "unknown" {
                        Picker(cookingText("Used from"), selection: $row.lotID) {
                            Text(cookingText(row.mode == "known" ? "Choose a lot" : "Source not tracked")).tag(nil as UUID?)
                            ForEach(need.lots) { lot in Text(verbatim: lotLabel(lot, among: need.lots)).tag(Optional(lot.id)) }
                        }
                    }
                    if row.mode == "known", let lot = need.lots.first(where: { $0.id == row.lotID }), let count = lot.quantity {
                        TextField(cookingText("Actual amount, such as 1/2"), text: $row.amount)
                        Picker(cookingText("Unit"), selection: $row.unit) {
                            ForEach(units(count.unit), id: \.self) { Text(cookingText($0)).tag($0) }
                        }.onAppear { if !units(count.unit).contains(row.unit) { row.unit = count.unit } }
                        .onChange(of: lot.id) { _, _ in row.unit = count.unit }
                    }
                    if rows.filter({ $0.needID == need.id }).count > 1 {
                        Button(cookingText("Remove split"), role: .destructive) { rows.removeAll { $0.id == row.id } }
                    }
                }
            }
            Button(cookingText("Add another lot")) { rows.append(ActualUse(needID: need.id)) }.disabled(rows.count >= 200)
        } header: {
            VStack(alignment: .leading) {
                Text(verbatim: need.name)
                if !need.groupNames.isEmpty { Text(verbatim: need.groupNames.joined(separator: " · ")) }
                if let q = need.quantity { Text(verbatim: cookingText("Planned amount") + " · " + physicalLabel(q)) }
            }
        }
    }
    private func load() async {
        failed = false
        guard allowed else { review = nil; resolution = nil; return }
        do {
            let next: SharedCookReview
            do {
                next = try await model.sharedCookReview(occurrence: occurrence, includePortions: paid)
            } catch ClientError.service(let status, _, _, _) where paid && [403, 503].contains(status) {
                next = try await model.sharedCookReview(occurrence: occurrence)
            }
            guard allowed, !Task.isCancelled else { return }
            if next != review {
                review = next; servings = min(1000, max(1, next.plannedPortions)); outputs = []
                rows = next.needs.map { ActualUse(needID: $0.id) }
            }
        } catch { if !Task.isCancelled { review = nil; failed = true } }
    }
    private func idValue(_ id: UUID) -> JSONValue { .string(id.uuidString.lowercased()) }
    private func physicalLabel(_ quantity: SharedMealQuantity) -> String {
        let amount = quantity.amount
        let value = amount.denominator == 1 ? String(amount.numerator) : "\(amount.numerator)/\(amount.denominator)"
        return value + " " + cookingText(quantity.unit)
    }
    private func lotLabel(_ lot: SharedCookReview.Lot, among choices: [SharedCookReview.Lot]) -> String {
        let count = lot.quantity.map(physicalLabel) ?? cookingText("Count unknown")
        var label = [lot.name, cookingText(lot.location), count].joined(separator: " · ")
        if choices.contains(where: { $0.id != lot.id && $0.name == lot.name && $0.location == lot.location && $0.quantity == lot.quantity }) {
            label += " · " + String(lot.id.uuidString.prefix(8))
        }
        return label
    }
    private func units(_ unit: String) -> [String] {
        let groups = [["gram","kilogram","ounce","pound"],["milliliter","liter","fluidOunce","cup"],["count"]]
        return groups.first { $0.contains(unit) } ?? [unit]
    }
    private func quantity(_ input: String, unit: String) -> JSONValue? {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let n = Int(parts[0]), (1...1_000_000_000).contains(n),
              let d = Int(parts.count == 1 ? "1" : String(parts[1])), (1...1_000_000_000).contains(d) else { return nil }
        return .object(["unit": .string(unit), "originalLiteral": .string(input),
                        "amount": .object(["numerator": .integer(n), "denominator": .integer(d)])])
    }
    private func commandUses(_ review: SharedCookReview) -> [JSONValue]? {
        var uses: [JSONValue] = [], pairs = Set<String>()
        for row in rows {
            guard let need = review.needs.first(where: { $0.id == row.needID }) else { return nil }
            var use: [String: JSONValue] = ["kind": .string(row.mode), "needId": idValue(row.needID), "rowId": idValue(row.id)]
            let lot = need.lots.first { $0.id == row.lotID }
            let pair = row.needID.uuidString + "/" + (lot?.id.uuidString ?? "")
            guard pairs.insert(pair).inserted else { return nil }
            switch row.mode {
            case "known":
                guard let lot, let count = lot.quantity, units(count.unit).contains(row.unit), let q = quantity(row.amount, unit: row.unit) else { return nil }
                use["lotId"] = idValue(lot.id); use["headId"] = idValue(lot.headId); use["quantity"] = q
            case "unknown": use["lotId"] = lot.map { idValue($0.id) } ?? .null; use["headId"] = lot.map { idValue($0.headId) } ?? .null
            case "notUsed": guard rows.filter({ $0.needID == row.needID }).count == 1 else { return nil }
            default: return nil
            }
            uses.append(.object(use))
        }
        return uses
    }
    private func save(_ review: SharedCookReview) async {
        guard let uses = commandUses(review), validAllocations(review) else { return }
        let values = outputs.map { out -> JSONValue in
            var fields: [String: JSONValue] = ["lotId": idValue(out.id), "name": .string(out.name),
                "portions": .integer(out.portions), "location": .string(out.location)]
            if out.includeUseFirst { fields["useFirstAt"] = .string(out.useFirstAt.ISO8601Format()) }
            if !out.allocations.isEmpty {
                fields["allocations"] = .array(out.allocations.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, portions in
                    .object(["needId": idValue(id), "portions": .integer(portions)])
                })
            }
            return .object(fields)
        }
        await submit("cook.complete", ["uses": .array(uses), "outputs": .array(values), "servings": .integer(servings)], review)
    }
    private func submit(_ kind: String, _ fields: [String: JSONValue], _ page: SharedCookReview) async {
        guard allowed, review == page, model.pending == nil else { return }
        await model.recordSharedCook(kind: kind, fields: fields, review: page)
        if allowed { await load() }
    }
}
