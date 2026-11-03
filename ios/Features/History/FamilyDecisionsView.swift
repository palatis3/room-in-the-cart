import SwiftUI
import HouseholdClient

private func fd(_ key: String) -> String { HistoryCopy.text(key) }
private func cleanDecisionField(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}
private func decisionKind(_ kind: FamilyDecisionKind) -> String {
    switch kind {
    case .approval: fd("Approval")
    case .exclusion: fd("Exclusion")
    case .preference: fd("Preference")
    }
}

struct FamilyDecisionsEntry: View {
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var pickup: PickupModel
    var localShopID: UUID?
    var initialDish = ""
    var body: some View {
        Group {
            if let access = household.decisionAccess, let service = household.service {
                FamilyDecisionServiceView(access: access, service: service, household: household, initialDish: initialDish, localShopID: localShopID)
                    .id(access)
            } else {
                List {
                    PickupDecisionsLink(shopID: localShopID)
                    Text(fd("Connect an adult household account to record a shared decision."))
                    NavigationLink(HistoryCopy.text("Open household")) { HouseholdSettingsView(model: household) }
                }
            }
        }.task { await pickup.load() }.navigationTitle(fd("Family decision history"))
    }
}

private struct PickupDecisionsLink: View {
    @EnvironmentObject private var pickup: PickupModel
    let shopID: UUID?
    var reviewForHousehold: ((FamilyDecisionInput) -> Void)? = nil
    var body: some View {
        NavigationLink(fd("Saved pickup decisions on this iPhone")) {
            let journeys = pickup.journeys.filter { shopID == nil || $0.id == shopID }
            LocalDecisionList(evidence: journeys.flatMap(PickupDecisionEvidence.records), reviewForHousehold: reviewForHousehold)
        }
    }
}

private struct LocalDecisionList: View {
    let evidence: [PickupDecisionEvidence]
    let reviewForHousehold: ((FamilyDecisionInput) -> Void)?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if evidence.isEmpty { Text(fd("Saved store preferences and reviewed meal repairs will appear here.")) }
            ForEach(evidence) { item in
                Section {
                    if let dish = item.draft.dish { Text(dish).font(.headline) }
                    if let product = item.draft.product { Text(product) }
                    if let occasion = item.draft.occasion { Text(occasion) }
                    Text(item.draft.decision)
                    Text(fd("Applies to this pickup"))
                    ForEach(item.exclusions, id: \.self) { exclusion in LabeledContent(fd("Exclusion"), value: exclusion) }
                    Text(fd("Meal outcome unconfirmed"))
                    if let response = item.retailerResponse { LabeledContent(fd("Entered retailer response"), value: response) }
                    ForEach(item.arrivals, id: \.key) { arrival in
                        LabeledContent(fd("Recorded arrival"), value: "\(arrival.itemName) · \(pQuantity(arrival.received))")
                    }
                    if let reviewForHousehold {
                        Button(fd("Prepare a shared copy for review")) {
                            reviewForHousehold(item.draft); dismiss()
                        }
                    }
                }
            }
        }.navigationTitle(fd("Saved pickup decisions on this iPhone"))
    }
}

private struct FamilyDecisionServiceView: View {
    @ObservedObject var household: HouseholdModel
    let localShopID: UUID?
    @StateObject private var model: FamilyDecisionModel
    @State private var draft = FamilyDecisionInput(kind: .preference, dish: nil, product: nil, occasion: nil, decision: "", outcome: nil)
    @State private var chosenShop: UUID?
    @State private var recordID = ""
    @State private var dish: String
    @State private var product = ""
    @State private var occasion = ""
    @State private var observation = ""
    @State private var editing = false
    @State private var confirming: ReviewedAction?
    private struct ReviewedAction: Identifiable {
        let id = UUID()
        let shopID: UUID
        let recordID: UUID?
        let action: FamilyDecisionAction
    }
    init(access: FamilyDecisionAccess, service: HouseholdService, household: HouseholdModel, initialDish: String, localShopID: UUID?) {
        self.localShopID = localShopID
        self.household = household
        _chosenShop = State(initialValue: access.shopID)
        _dish = State(initialValue: initialDish)
        _model = StateObject(wrappedValue: .init(access: access, service: service, store: household.decisionStore,
            currentAccess: { [weak household] in household?.decisionAccess }))
    }

    var body: some View {
        List {
            PickupDecisionsLink(shopID: localShopID, reviewForHousehold: model.canWrite ? { input in
                draft = input; editing = true
            } : nil)
            if editing && chosenShop == nil { Text(fd("Choose a shared shop, then review the copy before saving it.")) }
            if model.busy { ProgressView(fd("Checking decision records…")) }
            if let notice = model.notice { Text(notice) }
            if model.pending != nil {
                Section(fd("Saved retry")) {
                    Text(fd("The service may already have this change. Retry the original to check it."))
                    Button(fd("Retry original change")) { Task { await model.retry() } }
                    Button(fd("Discard local retry"), role: .destructive) { Task { await model.discardRetry() } }
                }
            }
            Section(fd("Shared shop for this record")) {
                Picker(fd("Shared shop"), selection: $chosenShop) {
                    Text(fd("Choose a shop")).tag(nil as UUID?)
                    ForEach(model.shops) { shop in
                        let date = serviceDate(shop.createdAt)?.formatted(date: .abbreviated,time: .shortened) ?? shop.createdAt
                        Text(verbatim: "\(date) · \(shop.id.suffix(8))").tag(UUID(uuidString: shop.id))
                    }
                }
                if model.shopCursor != nil { Button(fd("More shops")) { Task { await model.moreShops() } } }
                NavigationLink(HistoryCopy.text("Choose shared shop")) { HouseholdShopSelector(household: household) }
                Button(fd("Refresh decision access")) { Task { await model.load() } }
            }
            if let shopID = chosenShop, model.shops.contains(where: { UUID(uuidString:$0.id) == shopID }) {
                Section(fd("Free saved decisions")) {
                    ForEach(model.refs.filter { $0.shopID == shopID }) { ref in
                        Button { Task { await model.open(shopID: shopID, id: ref.id) } } label: {
                            Text(verbatim: "\(fd("Saved decision")) · \(ref.id.uuidString.suffix(8))")
                        }
                    }
                    TextField(fd("Decision ID from another device"), text: $recordID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(fd("Open saved decision")) {
                        if let id = UUID(uuidString: recordID) { Task { await model.open(shopID: shopID, id: id) } }
                    }.disabled(UUID(uuidString: recordID) == nil)
                }
                DisclosureGroup(fd("Record a decision"), isExpanded: $editing) {
                    Picker(fd("Decision type"), selection: $draft.kind) {
                        ForEach(FamilyDecisionKind.allCases, id: \.self) { Text(decisionKind($0)).tag($0) }
                    }
                    TextField(fd("Dish"), text: input(\.dish))
                    TextField(fd("Product"), text: input(\.product))
                    TextField(fd("Occasion"), text: input(\.occasion))
                    TextField(fd("What was decided?"), text: $draft.decision, axis: .vertical)
                    TextField(fd("Observed outcome, if known"), text: input(\.outcome), axis: .vertical)
                    Text(fd("Leave the outcome blank until someone observes what happened."))
                    Text(fd("Enter at least one dish, product or occasion. Each label allows 120 characters. Decision and outcome allow 500 each.")).font(.footnote)
                    Button(fd("Review shared decision")) {
                        confirming = .init(shopID: shopID, recordID: nil, action: .create(draft))
                    }.disabled(!model.canWrite || (try? draft.validate()) == nil)
                }
            }
            Section(fd("Search household decisions")) {
                TextField(fd("Filter by dish"), text: $dish)
                TextField(fd("Filter by product"), text: $product)
                TextField(fd("Filter by occasion"), text: $occasion)
                Button(fd("Search decisions")) { search() }
                ForEach(model.results) { result in
                    Button { Task { await model.open(shopID: result.shopId, id: result.id) } } label: {
                        VStack(alignment: .leading) { Text(result.decision); Text(result.dish ?? result.product ?? result.occasion ?? "").font(.caption) }
                    }
                }
                if model.searched && model.results.isEmpty { Text(fd("No matching decisions.")) }
                if model.cursor != nil { Button(fd("More decisions")) { search(more: true) } }
            }
            if let record = model.record { detail(record) }
        }
        .disabled(model.busy)
        .onChange(of: [dish,product,occasion]) { _,_ in model.forgetSearch() }
        .onChange(of: chosenShop) { _,_ in
            recordID = ""; observation = ""; model.closeRecord()
        }
        .onChange(of: model.record) { _,_ in observation = "" }
        .onChange(of: model.lastWrite) { _,_ in draft = .init(kind:.preference,dish:nil,product:nil,occasion:nil,decision:"",outcome:nil); observation = ""; editing = false }
        .task { await model.load() }
        .sheet(item: $confirming) { review in
            NavigationStack {
                List {
                    LabeledContent(fd("Shared shop"), value: review.shopID.uuidString)
                    switch review.action {
                    case .create(let input):
                        Text(decisionKind(input.kind))
                        if let dish = input.dish { LabeledContent(fd("Dish"), value: dish) }
                        if let product = input.product { LabeledContent(fd("Product"), value: product) }
                        if let occasion = input.occasion { LabeledContent(fd("Occasion"), value: occasion) }
                        Text(input.decision)
                        Text(input.outcome ?? fd("Outcome unconfirmed"))
                    case .observe(_,let text): Text(text)
                    case .promote:
                        Text(model.record?.decision ?? "")
                        Text(fd("Keep this preference for future review. Future baskets still require shopper approval."))
                    }
                    Button(fd("Confirm shared change")) {
                        confirming = nil
                        Task { await model.save(shopID: review.shopID, recordID: review.recordID, action: review.action) }
                    }.disabled(!model.canWrite)
                }.navigationTitle(fd("Review shared change"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { confirming = nil } } }
            }
        }
    }
    @ViewBuilder private func detail(_ record: FamilyDecisionRecord) -> some View {
        Section(fd("Decision details")) {
            Text(decisionKind(record.kind)).font(.headline)
            LabeledContent(fd("Shared shop"), value: String(record.shopId.uuidString.suffix(8)))
            Text(record.decision)
            if let dish = record.dish { LabeledContent(fd("Dish"), value: dish) }
            if let product = record.product { LabeledContent(fd("Product"), value: product) }
            if let occasion = record.occasion { LabeledContent(fd("Occasion"), value: occasion) }
            Text(record.scope == .lasting ? fd("Retained for future review") : fd("Applies to this pickup"))
            LabeledContent(fd("Observed outcome"), value: record.outcome ?? fd("Outcome unconfirmed"))
            LabeledContent(fd("Decision ID"), value: record.id.uuidString).textSelection(.enabled)
            if let date = serviceDate(record.recordedAt) { LabeledContent(fd("Recorded"), value: date.formatted()) }
            if let date = record.observedAt.flatMap(serviceDate) { LabeledContent(fd("Outcome recorded"), value: date.formatted()) }
            if let date = record.promotedAt.flatMap(serviceDate) { LabeledContent(fd("Preference retained"), value: date.formatted()) }
            DisclosureGroup(record.outcome == nil ? fd("Add observed outcome") : fd("Correct observed outcome")) {
                TextField(fd("What actually happened?"), text: $observation, axis: .vertical)
                Button(fd("Review observed outcome")) {
                    confirming = .init(shopID: record.shopId, recordID: record.id, action: .observe(version:record.version,text:observation))
                }.disabled(!model.canWrite || cleanDecisionField(observation) == nil || observation.utf16.count > 500)
            }
            if record.kind == .preference && record.scope == .oneShop {
                Button(fd("Review keeping this preference")) {
                    confirming = .init(shopID: record.shopId, recordID: record.id, action: .promote(version:record.version))
                }.disabled(!model.canWrite)
            }
        }
    }
    private func input(_ key: WritableKeyPath<FamilyDecisionInput,String?>) -> Binding<String> {
        Binding(get: { draft[keyPath:key] ?? "" }, set: { draft[keyPath:key] = $0.isEmpty ? nil : $0 })
    }
    private func search(more: Bool = false) {
        Task { await model.search(dish:cleanDecisionField(dish), product:cleanDecisionField(product), occasion:cleanDecisionField(occasion),more:more) }
    }
}
