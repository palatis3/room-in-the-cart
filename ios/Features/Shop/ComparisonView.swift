import SwiftUI
import CoreDomain

struct ComparisonView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: ComparisonModel
    @State private var reviewing: Bool
    private enum ResultFocus: Hashable { case summary, saved, error }
    @AccessibilityFocusState private var resultFocused: ResultFocus?
    @FocusState private var inputFocused: String?

    init(draft: ComparisonDraft = ComparisonDraft(), savedAt: Date? = nil) {
        let model = ComparisonModel(draft: draft)
        model.savedAt = savedAt
        _model = StateObject(wrappedValue: model)
        _reviewing = State(initialValue: savedAt != nil)
    }

    var body: some View {
        Group {
            if reviewing, let result = model.result {
                results(result)
            } else {
                editor
            }
        }
        .workingSurface()
        .navigationTitle(tr("Compare packs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if reviewing {
                if #available(iOS 26.0, *) {
                    editToolbar.sharedBackgroundVisibility(.hidden)
                } else {
                    editToolbar
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(tr("Done")) { inputFocused = nil }
            }
        }
        .onAppear { if reviewing { model.compare() } }
    }

    private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { reviewing = false; model.savedAt = nil } label: {
                Text(tr("Edit")).font(.body.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Theme.ink).padding(.horizontal, 16)
                    .frame(minHeight: 44).background(Theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(Color("control_edge"), lineWidth: 1.5))
            }.buttonStyle(.plain).accessibilityIdentifier("editComparison")
                .disabled(model.saving).tint(Theme.ink)
        }
    }

    private var editor: some View {
        Form {
            Section {
                Text(tr("Enough food. The right pack.")).font(.title2.bold())
                Text(tr("Compare the cost of enough usable food for one item. No account or connection needed."))
                    .foregroundStyle(Theme.secondary)
            }.listRowBackground(Theme.surface)
            Section(tr("What you need")) {
                TextField(tr("Item name"), text: $model.draft.item, axis: .vertical)
                    .focused($inputFocused, equals: "itemName").accessibilityIdentifier("itemName")
                entry("Total amount needed", text: $model.draft.needed, id: "needed")
                unitPicker("Needed unit", selection: $model.draft.unit)
            }
            Section {
                entry("Confirmed usable amount at home", text: $model.draft.stock, id: "stock")
                entry("Protected portions within the total", text: $model.draft.protected, id: "protected")
            } header: { Text(tr("Already accounted for")) } footer: {
                Text(tr("Use the needed unit. Count only stock matched to this item and available for this need. Protected lunch portions are already inside the total, not extra. Leave unconfirmed stock blank."))
            }
            offerSection("Pack A", label: $model.draft.aLabel, quantity: $model.draft.aQuantity, unit: $model.draft.aUnit, price: $model.draft.aPrice, prefix: "a")
            offerSection("Pack B", label: $model.draft.bLabel, quantity: $model.draft.bQuantity, unit: $model.draft.bUnit, price: $model.draft.bPrice, prefix: "b")
            Section {
                entry("Item spending limit (USD, optional)", text: $model.draft.cap, id: "itemCap")
            } footer: { Text(tr("This limit covers this item only. Other groceries, fees and taxes are not included.")) }
            if let error = model.error { errorRow(error) }
            Section {
                Button {
                    inputFocused = nil
                    model.compare()
                    if model.result != nil, model.error == nil { reviewing = true; resultFocused = .summary }
                    else { resultFocused = .error }
                } label: { Text(tr("Compare enough food")) }
                .buttonStyle(PrimaryAction()).accessibilityIdentifier("compare")
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
        }
    }

    private func entry(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr(label)).font(.subheadline).foregroundStyle(Theme.secondary)
            TextField(tr("Unknown if blank"), text: text)
                .keyboardType(.decimalPad).focused($inputFocused, equals: id)
                .accessibilityLabel(tr(label)).accessibilityIdentifier(id)
                .frame(minHeight: 44)
        }
    }

    private func unitPicker(_ label: String, selection: Binding<UnitOfMeasure>) -> some View {
        Picker(tr(label), selection: selection) {
            ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(unit.displayName).tag(unit) }
        }.frame(minHeight: 44)
    }

    private func offerSection(_ title: String, label: Binding<String>, quantity: Binding<String>, unit: Binding<UnitOfMeasure>, price: Binding<String>, prefix: String) -> some View {
        Section {
            TextField(tr("Pack name (optional)"), text: label, axis: .vertical)
                .focused($inputFocused, equals: prefix + "Label").accessibilityIdentifier(prefix + "Label")
            entry("Usable amount in one pack", text: quantity, id: prefix + "Quantity")
            unitPicker("Pack unit", selection: unit)
            entry("Price for one pack (USD)", text: price, id: prefix + "Price")
        } header: { Text(tr(title)) } footer: {
            Text(tr("Enter the usable amount, not just the printed pack size. Leave an unknown weight, yield or price blank."))
        }
    }

    private func results(_ result: CoreDomain.ComparisonResult) -> some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                resultList(result)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                // Reserve a real layout boundary above the floating tab bar.
                // The opaque footer continues behind it, so quantities cannot
                // be painted into the navigation region while scrolling.
                Theme.canvas.frame(height: 8)
                    .background(Theme.canvas.ignoresSafeArea(edges: .bottom))
                    .accessibilityHidden(true)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
    }

    private func resultList(_ result: CoreDomain.ComparisonResult) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.draft.item.isEmpty ? tr("One item") : model.draft.item).font(.title.bold())
                    Text(tr("Item-only comparison")).font(.headline)
                    Text(tr("Other groceries, fees and taxes are not included. This does not establish whether the whole pickup fits your budget."))
                        .foregroundStyle(Theme.secondary)
                    if !model.draft.needed.isEmpty {
                        Text(message("Total need: %@ %@", model.draft.needed, model.draft.unit.displayName))
                    }
                    if !model.draft.protected.isEmpty {
                        Text(message("Protected within that total: %@ %@", model.draft.protected, model.draft.unit.displayName))
                    }
                }.accessibilityElement(children: .combine).accessibilityFocused($resultFocused, equals: .summary)
            }
            resultSection(result.offerA, name: model.draft.aLabel.isEmpty ? tr("Pack A") : model.draft.aLabel, preferred: result.preferredOfferID == "a")
            resultSection(result.offerB, name: model.draft.bLabel.isEmpty ? tr("Pack B") : model.draft.bLabel, preferred: result.preferredOfferID == "b")
            if result.offerA.isResolved && result.offerB.isResolved && result.preferredOfferID == nil {
                Section { Text(tr("Both options cost the same for this need.")) }
            }
            Section {
                Text(tr("Source: prices and usable amounts you entered. Estimates for this item only."))
                    .font(.body).fixedSize(horizontal: false, vertical: true).foregroundStyle(Theme.secondary)
                if let date = model.savedAt {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(tr("Saved on this iPhone"), systemImage: "checkmark.circle")
                            .font(.headline).accessibilityIdentifier("savedStatus")
                        Text(date.formatted(date: .complete, time: .shortened))
                            .font(.footnote)
                    }.accessibilityElement(children: .combine).accessibilityFocused($resultFocused, equals: .saved)
                } else {
                    Button {
                        Task {
                            await model.save(in: app.store)
                            await app.refresh()
                            if model.savedAt != nil { resultFocused = .saved }
                            else { resultFocused = .error }
                        }
                    } label: { Text(tr(model.saving ? "Saving…" : "Save comparison")) }
                        .buttonStyle(PrimaryAction()).disabled(model.saving)
                        .accessibilityIdentifier("saveComparison")
                }
            }
            if let error = model.error { errorRow(error) }
        }
    }

    private func resultSection(_ result: OfferResult, name: String, preferred: Bool) -> some View {
        Section {
            if let cost = result.totalCost {
                Text(moneyText(cost)).font(.largeTitle.bold()).monospacedDigit()
                    .accessibilityLabel(message("Item cost to buy enough: %@", moneyText(cost)))
                    .accessibilityIdentifier(result.offerID + "Total")
            } else { Label(tr("Cost unresolved"), systemImage: "questionmark.circle").font(.title2.bold()) }
            if preferred { Text(tr("Lower cost to buy enough for this item")).font(.headline) }
            if let packs = result.packsToBuy {
                Text(message("Whole packs to buy: %@", packs.formatted())).monospacedDigit()
                    .accessibilityIdentifier(result.offerID + "Packs")
            }
            if let purchased = result.purchasedAmount {
                Text(message("Usable amount to buy: %@ %@", amountText(purchased), model.draft.unit.displayName))
            }
            if let shortage = result.remainingNeed, shortage > .zero {
                Text(message("Still needed: %@ %@", amountText(shortage), model.draft.unit.displayName)).font(.headline)
            }
            if let leftover = result.leftover {
                Text(message("Left after the total need: %@ %@", amountText(leftover), model.draft.unit.displayName))
            }
            if let headroom = result.itemHeadroom {
                Text(message(headroom.minorUnits < 0 ? "Over the item limit: %@" : "Room within the item limit: %@",
                             moneyText(Money(minorUnits: headroom.minorUnits < 0 ? -headroom.minorUnits : headroom.minorUnits))))
                    .font(.headline)
            }
            if let ceiling = result.unitCeiling {
                Text(message("Maximum per pack for this item limit: %@", moneyText(ceiling)))
            }
            ForEach(result.issues, id: \.self) { issue in
                Label(issue.explanation, systemImage: "questionmark.circle")
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier(result.offerID + "Issue_" + issue.rawValue)
            }
        } header: { Text(name) }
    }

    private func errorRow(_ text: String) -> some View {
        Section { Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(Color("error")).accessibilityFocused($resultFocused, equals: .error) }
    }
}

extension ComparisonIssue {
    var explanation: String {
        switch self {
        case .neededQuantityUnknown: return tr("How much do you need? Enter the total amount to compare enough food.")
        case .atHomeConversionUnknown: return tr("Confirm how the available stock converts to the needed unit.")
        case .protectedConversionUnknown: return tr("Confirm the unit for protected portions.")
        case .usableQuantityUnknown: return tr("How much usable food is in one pack? Leave this unresolved until you know.")
        case .usableConversionUnknown: return tr("These units need a confirmed conversion for this food. Enter a known usable amount in the needed unit, or leave unresolved.")
        case .noUsableYield: return tr("This pack has no usable food for the need. Choose another pack or correct its usable amount.")
        case .priceUnknown: return tr("What is the price for one pack? The cost stays unknown until you enter it.")
        }
    }
}
