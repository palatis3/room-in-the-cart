import SwiftUI
import OSLog
import CoreDomain
import LocalStore

/// Wait for the iOS 17 push to finish before mounting the comparison's native controls.
struct NewComparisonDestination: View {
    @State private var appeared = false

    var body: some View {
        if #available(iOS 18, *) {
            ComparisonView()
        } else if appeared {
            ComparisonView()
        } else {
            ProgressView(tr("Compare packs"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
                .background { ComparisonAppearanceObserver { appeared = true } }
                .navigationTitle(tr("Compare packs"))
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ComparisonAppearanceObserver: UIViewControllerRepresentable {
    let appeared: @MainActor () -> Void
    private static let logger = Logger(subsystem: "dev.roominthecart", category: "comparison-navigation")

    final class Controller: UIViewController {
        var appeared: (@MainActor () -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            ComparisonAppearanceObserver.logger.debug("Comparison transition appeared")
            let completion = appeared
            appeared = nil
            Task { @MainActor in completion?() }
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        Self.logger.debug("Preparing comparison transition")
        let controller = Controller()
        controller.view.isUserInteractionEnabled = false
        controller.view.accessibilityElementsHidden = true
        controller.appeared = appeared
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}
}

struct ComparisonView: View {
    @Environment(\.pantryDigestAccess) private var priceAccess
    @Environment(\.scenePhase) private var scene
    @EnvironmentObject private var workspace: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var child: GuardianChildCoordinator
    private let allowsPersonalPrices: Bool
    private var priceIdentity: CapturePrivateIdentity? {
        guard allowsPersonalPrices, scene == .active, UIApplication.shared.isProtectedDataAvailable,
              !child.presented, household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: workspace, household: household)
    }
    @EnvironmentObject private var app: AppModel
    @StateObject private var model: ComparisonModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var stockExpanded: Bool
    private enum MissingInput: Hashable, Identifiable {
        case price(ComparisonPack)
        case amount(ComparisonPack)
        var id: Self { self }
    }
    @State private var missingInput: MissingInput?
    @State private var reviewing: Bool
    private enum ResultFocus: Hashable { case summary, saved, toolbarSaved, error }
    @AccessibilityFocusState private var resultFocused: ResultFocus?
    @FocusState private var inputFocused: String?

    init(draft: ComparisonDraft = ComparisonDraft(), saved: SavedComparison? = nil, allowsPersonalPrices: Bool = true) {
        self.allowsPersonalPrices = allowsPersonalPrices
        let model = ComparisonModel(draft: draft, savedRevision: saved?.revision ?? 0)
        model.savedAt = saved?.savedAt
        _model = StateObject(wrappedValue: model)
        _reviewing = State(initialValue: saved != nil)
        _stockExpanded = State(initialValue: !draft.stock.isEmpty || !draft.protected.isEmpty)
    }

    var body: some View {
        Group {
            if reviewing, let comparison = model.comparison {
                results(comparison.result, inputs: comparison.inputs)
                    .toolbar {
                        if typeSize.isAccessibilitySize {
                            ToolbarItem(placement: .topBarTrailing) { accessibleSaveControl }
                        }
                    }
                    .sheet(item: $missingInput) { input in missingInputEditor(input) }
            } else {
                editor
            }
        }
        .workingSurface()
        .navigationTitle(tr("Compare packs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .keyboardDoneAction(visible: inputFocused != nil, title: tr("Done"),
                            identifier: inputFocused.map { "comparison.done." + $0 }) { inputFocused = nil }
        .onAppear { if reviewing { model.compare() } }
    }

    @ViewBuilder private var accessibleSaveControl: some View {
        if model.savedAt != nil {
            Text(tr("Saved"))
                .accessibilityLabel(tr("Saved on this iPhone"))
                .accessibilityIdentifier("comparison.toolbarSaved")
                .accessibilityFocused($resultFocused, equals: .toolbarSaved)
        } else {
            Button(tr("Save")) { saveComparison(focusAfterSave: .toolbarSaved) }
                .accessibilityLabel(tr(model.saving ? "Saving…" : "Save comparison"))
                .accessibilityIdentifier("comparison.toolbarSave")
                .disabled(model.saving)
        }
    }

    private func saveComparison(focusAfterSave: ResultFocus) {
        Task {
            guard !model.saving, model.savedAt == nil else { return }
            await model.save(in: app.store)
            await app.refresh()
            guard reviewing else { return }
            if model.savedAt != nil { resultFocused = focusAfterSave }
            else if model.error != nil { resultFocused = .error }
        }
    }

    @ViewBuilder private func missingInputEditor(_ input: MissingInput) -> some View {
        switch input {
        case .price(let pack):
            MissingPackPriceEditor(target: pack) { literal in
                switch pack {
                case .a: model.draft.aPrice = literal
                case .b: model.draft.bPrice = literal
                }
                updateResult()
            }
        case .amount(let pack):
            MissingPackAmountEditor(pack: pack, unit: pack == .a ? model.draft.aUnit : model.draft.bUnit) { literal, unit in
                model.draft.setUsableAmount(literal, unit: unit, for: pack)
                updateResult()
            }
        }
    }

    private func updateResult() {
        missingInput = nil
        model.compare()
        reviewing = model.result != nil
        resultFocused = reviewing ? .summary : .error
    }

    private var editRow: some View {
        Button { reviewing = false } label: {
            HStack(spacing: 12) {
                Label(tr("Edit"), systemImage: "pencil")
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward").accessibilityHidden(true)
            }
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Theme.action)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier("editComparison")
    }

    private var editor: some View {
        WorkingForm {
            Section {
                Text(tr("What are you buying?")).font(.title.bold()).accessibilityAddTraits(.isHeader)
                WorkingField(tr("Item name")) {
                    workingTextField(tr("Item name"), text: $model.draft.item, axis: .vertical)
                        .focused($inputFocused, equals: "itemName").accessibilityIdentifier("itemName")
                        .frame(minHeight: 44)
                }
                entry("Total amount needed", text: $model.draft.needed, id: "needed")
                unitPicker("Needed unit", selection: $model.draft.unit, id: "neededUnit")
            } footer: {
                Text(tr("Compare the cost of enough usable food for one item. No account or connection needed."))
            }
            offerSection("Pack A", label: $model.draft.aLabel, quantity: $model.draft.aQuantity, unit: $model.draft.aUnit, price: $model.draft.aPrice, conversion: $model.draft.aConversion, prefix: "a")
            offerSection("Pack B", label: $model.draft.bLabel, quantity: $model.draft.bQuantity, unit: $model.draft.bUnit, price: $model.draft.bPrice, conversion: $model.draft.bConversion, prefix: "b")
            Section {
                entry("Item spending limit (USD, optional)", text: $model.draft.cap, id: "itemCap", keyboard: .decimalPad)
            } footer: { Text(tr("This limit covers this item only. Other groceries, fees and taxes are not included.")) }
            Section {
                DisclosureGroup(isExpanded: $stockExpanded) {
                    entry("Available at home", text: $model.draft.stock, id: "stock")
                    entry("Set aside within the total", text: $model.draft.protected, id: "protected")
                    Text(tr("Use the same unit as your shopping need. Count only food available for this item. Include any set-aside portions in the total you need."))
                        .font(.footnote).foregroundStyle(Theme.secondary)
                } label: {
                    Text(tr("Food at home and set-aside portions"))
                }
                .disclosureGroupStyle(LabeledFormDisclosureStyle(label: tr("Food at home and set-aside portions"),
                                                                identifier: "comparisonStockDisclosure"))
            }
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

    private func entry(_ label: String, text: Binding<String>, id: String, keyboard: UIKeyboardType = .numbersAndPunctuation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr(label)).font(.subheadline).foregroundStyle(Theme.secondary)
            workingTextField(tr("Unknown if blank"), text: text)
                .keyboardType(keyboard).focused($inputFocused, equals: id)
                .accessibilityLabel(tr(label)).accessibilityIdentifier(id)
                .frame(minHeight: 44)
        }
        // iOS 17 exposes the entire Form row as the text field's activation
        // frame. Its center can sit between the caption and the editor.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { inputFocused = id })
    }

    @ViewBuilder private func unitPicker(_ label: String, selection: Binding<UnitOfMeasure>, id: String) -> some View {
        let title = tr(label)
        let picker = Picker(title, selection: selection) {
            ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(unit.displayName).tag(unit) }
        }
        if typeSize.isAccessibilitySize {
            let value = selection.wrappedValue.displayName
            Menu {
                picker.pickerStyle(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline).foregroundStyle(Theme.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(value).foregroundStyle(Theme.action)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                            .foregroundStyle(Theme.action).accessibilityHidden(true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(title).accessibilityValue(value).accessibilityIdentifier(id)
        } else {
            picker.frame(minHeight: 44).accessibilityIdentifier(id)
        }
    }

    private func offerSection(_ title: String, label: Binding<String>, quantity: Binding<String>, unit: Binding<UnitOfMeasure>, price: Binding<String>, conversion: Binding<ComparisonConversion?>, prefix: String) -> some View {
        Section {
            entry("Usable amount in one pack", text: quantity, id: prefix + "Quantity")
            unitPicker("Pack unit", selection: unit, id: prefix + "Unit")
            entry("Price for one pack (USD)", text: price, id: prefix + "Price", keyboard: .decimalPad)
            WorkingField(tr("Pack name (optional)")) {
                workingTextField(tr("Pack name (optional)"), text: label, axis: .vertical)
                    .focused($inputFocused, equals: prefix + "Label").accessibilityIdentifier(prefix + "Label")
                    .frame(minHeight: 44)
            }
            PackConversionControl(packLabel: label.wrappedValue.isEmpty ? tr(title) : label.wrappedValue,
                                  sourceUnit: unit.wrappedValue, targetUnit: model.draft.unit,
                                  conversion: conversion, identifier: prefix + "Conversion")
            if let identity = priceIdentity {
                let scope = PantryDigestScope(origin: priceAccess?.scope.origin ?? identity.actorID, identity: identity)
                PackPaidPriceEditor(product: model.draft.item, packLabel: label.wrappedValue, quantity: quantity,
                                    unit: unit, price: price, access: priceAccess, current: { priceIdentity == identity }, prefix: prefix)
                    .id(scope.owner + scope.origin.uuidString + prefix)
            }
        } header: { Text(tr(title)) } footer: {
            Text(tr("Enter the usable amount, not just the printed pack size. Leave an unknown weight, yield or price blank."))
        }
    }

    private func results(_ result: CoreDomain.ComparisonResult, inputs: ComparisonRequest) -> some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                resultList(result, inputs: inputs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                // Reserve a real layout boundary above the floating tab bar.
                // The opaque footer continues behind it, so quantities cannot
                // be painted into the navigation region while scrolling.
                Theme.canvas.frame(height: 8)
                    .background(Theme.canvas.ignoresSafeArea(edges: .bottom))
                    .accessibilityHidden(true)
            }
            .fittingViewport(viewport.size)
        }
    }

    private func resultList(_ result: CoreDomain.ComparisonResult, inputs: ComparisonRequest) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Item-only comparison")).font(.subheadline.weight(.semibold))
                    Text(model.draft.item.isEmpty ? tr("One item") : model.draft.item).font(.title.bold())
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($resultFocused, equals: .summary)
                    if let summary = result.purchaseSummary {
                        Text(summary).font(.headline).accessibilityIdentifier("comparisonPurchaseSummary")
                    } else if let preferred = result.preferredOfferID {
                        let offer = preferred == inputs.offerA.id ? inputs.offerA : inputs.offerB
                        let name = offer.label.isEmpty ? tr(preferred == inputs.offerA.id ? "Pack A" : "Pack B") : offer.label
                        Label(message("%@ costs less for this need", name), systemImage: "checkmark.circle")
                            .font(.headline).accessibilityElement(children: .combine)
                            .accessibilityIdentifier("comparisonDecision")
                    } else {
                        Label(tr("Cost unresolved"), systemImage: "questionmark.circle").font(.headline)
                    }
                    Divider()
                    Text(tr("Cost in whole packs")).font(.subheadline.weight(.semibold))
                    if let cap = inputs.itemCap {
                        Text(message("Item spending limit: %@", moneyText(cap, locale: locale)))
                            .font(.subheadline).monospacedDigit()
                            .accessibilityIdentifier("comparisonItemLimit")
                    }
                    let rates = inputs.comparableUnitPrices
                    costLine(inputs.offerA, result: result.offerA, fallback: tr("Pack A"), unitPrice: rates?.a, unit: result.unit)
                    costLine(inputs.offerB, result: result.offerB, fallback: tr("Pack B"), unitPrice: rates?.b, unit: result.unit)
                }
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                .foregroundStyle(result.offerA.isResolved && result.offerB.isResolved ? Theme.onSelection : Theme.ink)
                .listRowBackground(result.offerA.isResolved && result.offerB.isResolved ? Theme.selection : Theme.warningSurface)
                recoveryActions(for: .a, result: result.offerA)
                recoveryActions(for: .b, result: result.offerB)
                editRow
            }
            Section {
                Text(tr("Other groceries, fees and taxes are not included. This does not establish whether the whole pickup fits your budget."))
                    .foregroundStyle(Theme.secondary)
                if let need = inputs.needed {
                    ComparisonMetric(message("Total need: %@ %@", need.originalLiteral, need.unit.comparisonLabel(for: need.amount)))
                }
                let stock = inputs.confirmedAtHome
                let stockText = stock.map { pQuantity($0.originalLiteral, unit: $0.unit, singular: $0.amount == .one, language: nil) }
                ComparisonMetric(ledgerFormat("Confirmed at home for this need: %@", stockText ?? recordsText("Not entered")),
                                 id: "comparisonConfirmedStock")
                if stock != nil, let remaining = result.offerA.amountToBuy {
                    ComparisonMetric(message("Needed after confirmed stock: %@", remainingQuantity(remaining)),
                                     id: "comparisonNeedAfterStock")
                }
                if let protected = inputs.protectedAmount {
                    ComparisonMetric(message("Protected within that total: %@ %@", protected.originalLiteral, protected.unit.comparisonLabel(for: protected.amount)))
                }
            }
            resultSection(result.offerA, offer: inputs.offerA, fallbackName: tr("Pack A"),
                          conversion: model.draft.aConversion, preferred: result.preferredOfferID == "a")
            resultSection(result.offerB, offer: inputs.offerB, fallbackName: tr("Pack B"),
                          conversion: model.draft.bConversion, preferred: result.preferredOfferID == "b")
            Section {
                ComparisonMetric(tr("Source: prices and usable amounts you entered. Estimates for this item only."), id: "comparisonSourceNote")
                if let date = model.savedAt {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(tr("Saved on this iPhone"), systemImage: "checkmark.circle")
                            .font(.headline).accessibilityIdentifier("savedStatus")
                        Text(date.formatted(date: .complete, time: .shortened))
                            .font(.footnote)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("comparisonSavedDetails")
                        .accessibilityFocused($resultFocused, equals: .saved)
                } else {
                    ComparisonSaveButton(title: tr(model.saving ? "Saving…" : "Save comparison"), enabled: !model.saving) {
                        saveComparison(focusAfterSave: .saved)
                    }
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color("error")).accessibilityFocused($resultFocused, equals: .error)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .accessibilityIdentifier("comparisonResultsScroll")
    }

    @ViewBuilder private func recoveryActions(for pack: ComparisonPack, result: OfferResult) -> some View {
        if result.issues.contains(.priceUnknown) {
            recoveryAction(pack.priceTitle, id: pack.rawValue + "AddPrice") { missingInput = .price(pack) }
        }
        if result.issues.contains(.usableQuantityUnknown) {
            recoveryAction(pack.amountTitle, id: pack.rawValue + "AddAmount") { missingInput = .amount(pack) }
        }
    }

    private func recoveryAction(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .foregroundStyle(Theme.action).accessibilityIdentifier(id)
    }

    private func costLine(_ offer: PackOffer, result: OfferResult, fallback: String,
                          unitPrice: Rational?, unit: UnitOfMeasure?) -> some View {
        let title = offer.label.isEmpty ? fallback : fallback + " · " + offer.label
        let cost = result.totalCost.map { moneyText($0, locale: locale) } ?? tr("Cost unresolved")
        return VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: title).fixedSize()
                    Spacer(minLength: 4)
                    Text(verbatim: cost).fontWeight(.semibold).monospacedDigit().fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                    Text(verbatim: cost).fontWeight(.semibold).monospacedDigit()
                }
            }
            if let unitPrice, let unit {
                Text(verbatim: comparisonUnitPriceText(unitPrice, in: unit, locale: locale))
                    .font(.subheadline).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(offer.id + "CostSummary")
    }

    private func remainingQuantity(_ amount: Rational) -> String {
        let (whole, remainder) = amount.numerator.quotientAndRemainder(dividingBy: amount.denominator)
        let text = whole > 0 && remainder > 0 ? "\(whole) \(remainder)/\(amount.denominator)" : amountText(amount)
        return pQuantity(text, unit: model.draft.unit, singular: amount == .one, language: nil)
    }

    private func resultSection(_ result: OfferResult, offer: PackOffer, fallbackName: String,
                               conversion: ComparisonConversion?, preferred: Bool) -> some View {
        Section {
            ComparisonMetric(offer.label.isEmpty ? fallbackName : offer.label, style: .headline, id: result.offerID + "Header", heading: true)
            if let cost = result.totalCost {
                Text(moneyText(cost)).font(.largeTitle.bold()).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message("Item cost to buy enough: %@", moneyText(cost)))
                    .accessibilityIdentifier(result.offerID + "Total")
            } else { Label(tr("Cost unresolved"), systemImage: "questionmark.circle").font(.title2.bold()) }
            if preferred { ComparisonMetric(tr("Lower cost to buy enough for this item"), style: .headline) }
            let amount = offer.usableQuantity.map { "\($0.originalLiteral) \($0.unit.comparisonLabel(for: $0.amount))" }
            ComparisonMetric(tr("Usable amount in one pack") + ": " + (amount ?? recordsText("Not entered")),
                             id: result.offerID + "PackQuantity")
            ComparisonMetric(tr("Price for one pack (USD)") + ": " + (offer.price.map(moneyText) ?? recordsText("Not entered")),
                             id: result.offerID + "PackPrice")
            if let conversion {
                ComparisonMetric(conversion.readableText(), id: result.offerID + "ConversionBasis")
            }
            if let packs = result.wholePacksText { ComparisonMetric(packs, id: result.offerID + "Packs") }
            if let purchased = result.purchasedText(in: model.draft.unit) { ComparisonMetric(purchased) }
            if let shortage = result.shortageText(in: model.draft.unit) { ComparisonMetric(shortage, style: .headline) }
            if let leftover = result.leftoverText(in: model.draft.unit) { ComparisonMetric(leftover) }
            if let limitText = result.itemLimitText { ComparisonMetric(limitText, style: .headline) }
            if let ceiling = result.unitCeilingText { ComparisonMetric(ceiling) }
            ForEach(result.issues, id: \.self) { issue in
                Label(issue.explanation, systemImage: "questionmark.circle")
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier(result.offerID + "Issue_" + issue.rawValue)
            }
        }
    }

    private func errorRow(_ text: String) -> some View {
        Section { Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(Color("error")).accessibilityFocused($resultFocused, equals: .error) }
    }
}

private extension ComparisonPack {
    var priceTitle: String { tr(self == .a ? "Add Pack A price" : "Add Pack B price") }
    var amountTitle: String { tr(self == .a ? "Enter Pack A usable amount" : "Enter Pack B usable amount") }
}

private struct MissingPackAmountEditor: View {
    let pack: ComparisonPack
    @State var unit: UnitOfMeasure
    let update: (String, UnitOfMeasure) -> Void
    @State private var literal = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WorkingForm {
                Section {
                    WorkingField(tr("Usable amount in one pack")) {
                        workingTextField(tr("Usable amount in one pack"), text: $literal)
                            .keyboardType(.numbersAndPunctuation).focused($focused)
                            .accessibilityIdentifier(pack.rawValue + "Quantity")
                    }
                    Picker(tr("Pack unit"), selection: $unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .accessibilityIdentifier(pack.rawValue + "Unit")
                    if invalid {
                        Label(tr("Enter the amount as a number or fraction, such as 3 or 1/2."),
                              systemImage: "exclamationmark.circle")
                            .foregroundStyle(Theme.warning)
                    }
                    Button(tr("Update comparison")) {
                        guard (try? ComparisonModel.quantity(literal, unit)) != nil else { invalid = true; return }
                        update(literal, unit)
                        dismiss()
                    }
                    .buttonStyle(PrimaryAction()).accessibilityIdentifier("comparison.updateAmount")
                }
            }
            .navigationTitle(pack.amountTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { dismiss() } } }
            .keyboardDoneAction(visible: focused, title: tr("Done"), identifier: "comparison.done." + pack.rawValue + "Quantity") {
                focused = false
            }
            .onAppear { focused = true }
        }
    }
}

private struct MissingPackPriceEditor: View {
    let target: ComparisonPack
    let update: (String) -> Void
    @State private var literal = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WorkingForm {
                Section {
                    WorkingField(tr("Price for one pack (USD)")) {
                        workingTextField(tr("Price for one pack (USD)"), text: $literal)
                            .keyboardType(.decimalPad).focused($focused)
                            .accessibilityIdentifier(target.rawValue + "Price")
                    }
                    if invalid {
                        Label(tr("Enter a price in USD with up to two decimal places."), systemImage: "exclamationmark.circle")
                            .foregroundStyle(Theme.warning)
                    }
                    Button(tr("Update comparison")) {
                        guard (try? ComparisonModel.money(literal)) != nil else { invalid = true; return }
                        update(literal)
                        dismiss()
                    }
                    .buttonStyle(PrimaryAction()).accessibilityIdentifier("comparison.updatePrice")
                }
            }
            .navigationTitle(target.priceTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancel")) { dismiss() } }
            }
            .keyboardDoneAction(visible: focused, title: tr("Done"), identifier: "comparison.done." + target.rawValue + "Price") {
                focused = false
            }
            .onAppear { focused = true }
        }
    }
}

struct PackConversionControl: View {
    let packLabel: String
    let sourceUnit: UnitOfMeasure
    let targetUnit: UnitOfMeasure
    @Binding var conversion: ComparisonConversion?
    let identifier: String
    @State private var editing = false

    var body: some View {
        if sourceUnit.dimension != targetUnit.dimension {
            if let conversion {
                Text(conversion.readableText()).font(.subheadline)
            }
            Button { editing = true } label: {
                Label(conversion == nil ? tr("Add ingredient conversion") : tr("Edit ingredient conversion"),
                      systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier(identifier)
            .sheet(isPresented: $editing) {
                PackConversionEditor(packLabel: packLabel, sourceUnit: sourceUnit, targetUnit: targetUnit,
                                     conversion: $conversion)
            }
        }
    }
}

private struct PackConversionEditor: View {
    let packLabel: String
    @Binding var conversion: ComparisonConversion?
    @State private var draft: ComparisonConversion
    @State private var showError = false
    @FocusState private var focusedField: String?
    @Environment(\.dismiss) private var dismiss

    init(packLabel: String, sourceUnit: UnitOfMeasure, targetUnit: UnitOfMeasure,
         conversion: Binding<ComparisonConversion?>) {
        self.packLabel = packLabel
        _conversion = conversion
        _draft = State(initialValue: conversion.wrappedValue ?? ComparisonConversion(
            sourceLiteral: "", targetLiteral: "", sourceUnit: sourceUnit, targetUnit: targetUnit))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                conversionForm
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                        // Give the next amount room above the keyboard and its Done bar on compact screens.
                        if let focusedField { scroll.scrollTo(focusedField, anchor: .top) }
                    }
            }
        }
    }

    private var conversionForm: some View {
        WorkingForm {
            Section {
                Text(tr("Enter two equivalent amounts for this food from the package label, a recipe, or your own measurement."))
                    .foregroundStyle(Theme.secondary)
                amountField(unit: draft.sourceUnit, text: $draft.sourceLiteral, id: "conversion.source")
                amountField(unit: draft.targetUnit, text: $draft.targetLiteral, id: "conversion.target")
                workingTextField(tr("Label or measurement note (optional)"), text: $draft.sourceNote, axis: .vertical)
                    .focused($focusedField, equals: "conversion.note")
                    .accessibilityIdentifier("conversion.note")
                    .id("conversion.note")
            } header: { Text(verbatim: packLabel) }
            Section {
                if showError {
                    Text(tr("Enter two positive amounts. Use a decimal or fraction and keep the source note brief."))
                        .foregroundStyle(Theme.warning)
                }
                Button(tr("Confirm conversion")) {
                    guard (try? draft.unitBasis()) != nil else { showError = true; return }
                    conversion = draft
                    dismiss()
                }.buttonStyle(PrimaryAction()).accessibilityIdentifier("conversion.confirm")
                if conversion != nil {
                    Button(tr("Remove conversion"), role: .destructive) { conversion = nil; dismiss() }
                        .accessibilityIdentifier("conversion.remove")
                }
            }
        }
        .workingSurface()
        .navigationTitle(tr("Ingredient conversion"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(tr("Cancel")) { dismiss() }.accessibilityIdentifier("conversion.cancel")
            }
        }
        .keyboardDoneAction(visible: focusedField != nil, title: tr("Done"), identifier: "conversion.done") {
            focusedField = nil
        }
    }

    private func amountField(unit: UnitOfMeasure, text: Binding<String>, id: String) -> some View {
        let label = message("Amount in %@", unit.displayName)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(Theme.secondary)
            workingTextField(label, text: text)
                .keyboardType(.numbersAndPunctuation)
                .focused($focusedField, equals: id)
                .accessibilityLabel(label).accessibilityIdentifier(id)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focusedField = id })
        .id(id)
    }
}

extension ComparisonIssue {
    var explanation: String {
        switch self {
        case .neededQuantityUnknown: return tr("How much do you need? Enter the total amount to compare enough food.")
        case .atHomeConversionUnknown: return tr("Confirm how the available stock converts to the needed unit.")
        case .protectedConversionUnknown: return tr("Confirm the unit for protected portions.")
        case .usableQuantityUnknown: return tr("How much usable food is in one pack? Leave this unresolved until you know.")
        case .usableConversionUnknown: return tr("Edit this pack to add a conversion from its label or a measurement. Until then, the number of packs to buy is unknown.")
        case .noUsableYield: return tr("This pack has no usable food for the need. Choose another pack or correct its usable amount.")
        case .priceUnknown: return tr("What is the price for one pack? The cost stays unknown until you enter it.")
        }
    }
}

/// A platform text label can remeasure a multiline result while the system changes
/// the preferred content size, including while the results list is scrolled.
private struct ComparisonMetric: UIViewRepresentable {
    let text: String
    let style: UIFont.TextStyle
    let id: String?
    let heading: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ text: String, style: UIFont.TextStyle = .body, id: String? = nil, heading: Bool = false) {
        self.text = text
        self.style = style
        self.id = id
        self.heading = heading
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byWordWrapping
        label.isAccessibilityElement = true
        label.isOpaque = true
        label.backgroundColor = .secondarySystemGroupedBackground
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.textColor = .label
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        label.font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        label.accessibilityIdentifier = id
        label.accessibilityTraits = heading ? [.header, .staticText] : .staticText
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        guard width > 0 else { return .zero }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(measured.height))
    }
}

/// Keep the title, hit target and VoiceOver button in the same native control as its font scales.
private struct ComparisonSaveButton: UIViewRepresentable {
    let title: String
    let enabled: Bool
    let save: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    final class Coordinator {
        var action: (() -> Void)?
        @objc func activate() { action?() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.layer.cornerRadius = 14
        button.accessibilityIdentifier = "saveComparison"
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = save
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        button.setTitle(title, for: .normal)
        button.backgroundColor = UIColor(Theme.action)
        button.setTitleColor(UIColor(Theme.onAction), for: .normal)
        button.isEnabled = enabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let height = uiView.titleLabel?.sizeThatFits(CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)).height ?? 0
        return CGSize(width: width, height: max(52, ceil(height) + 16))
    }
}

private struct PackPaidPriceEditor: View {
    let product: String
    let packLabel: String
    @Binding var quantity: String
    @Binding var unit: UnitOfMeasure
    @Binding var price: String
    let access: PantryDigestAccess?
    let current: @MainActor () -> Bool
    let prefix: String
    @EnvironmentObject private var pickup: PickupModel
    @State private var model: PantryModel?
    @State private var expanded = false
    @State private var scan = false
    @State private var printed: (line: PriceImageLine, proposal: ReviewedShelfImage.Proposal)?
    @State private var comparePrinted = false
    @State private var store = ""
    @State private var variant = ""
    @State private var conditions = ""
    @State private var tax: PrivatePriceEvidence.TaxTreatment?
    @State private var seenAt = Date()

    var body: some View {
        DisclosureGroup(pantryText("Compare with my last purchase"), isExpanded: $expanded) {
            if expanded, current() {
                Button(pantryText("Read a shelf label")) { scan = true }
                    .accessibilityIdentifier(prefix + ".shelfScan")
                if let printed {
                    Text(verbatim: printed.line.effectiveWording)
                    Text(pantryText("Check the USD price for one pack and its usable amount against this label."))
                    let proposal = printed.proposal
                    if scannedOffer != nil {
                        Toggle(pantryFormat("Compare the printed offer in %@", proposal.currencyCode ?? "USD"),
                               isOn: $comparePrinted)
                    }
                    if (proposal.currencyCode == nil || proposal.currencyCode == "USD"),
                       proposal.priceBasis == .bundle, (proposal.packages ?? 1) == 1,
                       let amount = proposal.amount, let size = proposal.packageSize {
                        Button(pantryText("Use this USD price and printed amount for one usable pack")) {
                            price = NSDecimalNumber(decimal: Decimal(amount.minorUnits) / 100).stringValue
                            quantity = size.amount.description
                            unit = size.unit
                            conditions = proposal.conditions ?? ""
                            comparePrinted = false
                        }
                    }
                }
                TextField(pantryText("Brand or variant"), text: $variant)
                    .accessibilityIdentifier(prefix + ".paidVariant")
                TextField(pantryText("Store"), text: $store)
                TextField(pantryText("Promotion or membership conditions"), text: $conditions)
                ShelfTaxPicker(tax: $tax)
                if let model, access?.authorized() == true {
                    ShelfPaidPriceView(model: model, offer: comparePrinted ? scannedOffer ?? offer : offer, asOf: seenAt, store: store,
                                       isUnitLabel: comparePrinted && printed?.proposal.priceBasis == .unit)
                        .id(pickup.pantrySnapshot?.state.revision)
                } else {
                    Text(pantryText("No comparable paid price"))
                }
            }
        }
        .disclosureGroupStyle(LabeledFormDisclosureStyle(label: pantryText("Compare with my last purchase"),
                                                         identifier: prefix + ".paidHistory"))
        .task(id: expanded) {
            guard expanded, current(), access?.authorized() == true else { model = nil; return }
            model = pickup.makePantryModel()
            seenAt = Date()
        }
        .onChange(of: product) { _, _ in resetMatch() }
        .onChange(of: packLabel) { _, _ in resetMatch() }
        .sheet(isPresented: $scan) {
            NavigationStack {
                PriceImageReview(purpose: .shelf, authorized: { current() }, acceptShelf: { line in
                    guard current() else { return }
                    let proposal = ReviewedShelfImage.propose(line.effectiveWording)
                    printed = (line, proposal)
                    comparePrinted = false
                    conditions = proposal.conditions ?? ""
                })
            }
        }
        .privacySensitive()
    }

    private var offer: ShelfPriceOffer {
        let size = try? ComparisonModel.quantity(quantity, unit)
        return ShelfPriceOffer(product: product, variant: variant, pack: size.map { .init(perPackage: $0) },
                               amountMinor: (try? ComparisonModel.money(price))?.minorUnits,
                               currency: "USD", eligibility: conditions, tax: tax, basis: .usable)
    }
    private var scannedOffer: ShelfPriceOffer? {
        guard let printed else { return nil }
        let proposal = printed.proposal
        guard let amount = proposal.amount, proposal.priceBasis != .unknown,
              let size = proposal.rateQuantity ?? proposal.packageSize else { return nil }
        let bundle = PrivatePriceEvidence.Pack(count: proposal.priceBasis == .unit ? 1 : proposal.packages ?? 1, perPackage: size)
        return ShelfPriceOffer(product: product, variant: variant, pack: bundle, amountMinor: amount.minorUnits,
                               currency: proposal.currencyCode ?? "USD", eligibility: conditions, tax: tax)
    }
    private func resetMatch() {
        printed = nil; comparePrinted = false; variant = ""; conditions = ""; tax = nil
    }
}
