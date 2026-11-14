import SwiftUI
import CoreDomain
import LocalStore

struct ComparisonView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: ComparisonModel
    @State private var reviewing: Bool
    private enum ResultFocus: Hashable { case summary, saved, error }
    @AccessibilityFocusState private var resultFocused: ResultFocus?
    @FocusState private var inputFocused: String?

    init(draft: ComparisonDraft = ComparisonDraft(), saved: SavedComparison? = nil) {
        let model = ComparisonModel(draft: draft, savedRevision: saved?.revision ?? 0)
        model.savedAt = saved?.savedAt
        _model = StateObject(wrappedValue: model)
        _reviewing = State(initialValue: saved != nil)
    }

    var body: some View {
        Group {
            if reviewing, let comparison = model.comparison {
                results(comparison.result, inputs: comparison.inputs)
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
            if reviewing && !dynamicTypeSize.isAccessibilitySize {
                if #available(iOS 26.0, *) {
                    editToolbar.sharedBackgroundVisibility(.hidden)
                } else {
                    editToolbar
                }
            }
        }
        .keyboardDoneAction(visible: inputFocused != nil, title: tr("Done"),
                            identifier: inputFocused.map { "comparison.done." + $0 }) { inputFocused = nil }
        .onAppear { if reviewing { model.compare() } }
    }

    private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: editComparison) {
                Text(tr("Edit")).font(.body.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Theme.ink).padding(.horizontal, 16)
                    .frame(minHeight: 44).background(Theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(Color("control_edge"), lineWidth: 1.5))
            }.buttonStyle(.plain).accessibilityIdentifier("editComparison")
                .tint(Theme.ink)
        }
    }

    private func editComparison() { reviewing = false }

    /// Accessibility text sizes need a content row whose height can grow with the label.
    /// The navigation bar's compact toolbar host is retained only for standard text sizes.
    private var accessibleEditRow: some View {
        Button(action: editComparison) {
            Text(tr("Edit")).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.buttonStyle(.plain).foregroundStyle(Theme.ink)
            .accessibilityIdentifier("editComparison")
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
                unitPicker("Needed unit", selection: $model.draft.unit, id: "neededUnit")
            }
            Section {
                entry("Confirmed usable amount at home", text: $model.draft.stock, id: "stock")
                entry("Protected portions within the total", text: $model.draft.protected, id: "protected")
            } header: { Text(tr("Already accounted for")) } footer: {
                Text(tr("Use the needed unit. Count only stock matched to this item and available for this need. Protected lunch portions are already inside the total, not extra. Leave unconfirmed stock blank."))
            }
            offerSection("Pack A", label: $model.draft.aLabel, quantity: $model.draft.aQuantity, unit: $model.draft.aUnit, price: $model.draft.aPrice, conversion: $model.draft.aConversion, prefix: "a")
            offerSection("Pack B", label: $model.draft.bLabel, quantity: $model.draft.bQuantity, unit: $model.draft.bUnit, price: $model.draft.bPrice, conversion: $model.draft.bConversion, prefix: "b")
            Section {
                entry("Item spending limit (USD, optional)", text: $model.draft.cap, id: "itemCap", keyboard: .decimalPad)
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

    private func entry(_ label: String, text: Binding<String>, id: String, keyboard: UIKeyboardType = .numbersAndPunctuation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr(label)).font(.subheadline).foregroundStyle(Theme.secondary)
            TextField(tr("Unknown if blank"), text: text)
                .keyboardType(keyboard).focused($inputFocused, equals: id)
                .accessibilityLabel(tr(label)).accessibilityIdentifier(id)
                .frame(minHeight: 44)
        }
    }

    private func unitPicker(_ label: String, selection: Binding<UnitOfMeasure>, id: String) -> some View {
        Picker(tr(label), selection: selection) {
            ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(unit.displayName).tag(unit) }
        }.frame(minHeight: 44).accessibilityIdentifier(id)
    }

    private func offerSection(_ title: String, label: Binding<String>, quantity: Binding<String>, unit: Binding<UnitOfMeasure>, price: Binding<String>, conversion: Binding<ComparisonConversion?>, prefix: String) -> some View {
        Section {
            TextField(tr("Pack name (optional)"), text: label, axis: .vertical)
                .focused($inputFocused, equals: prefix + "Label").accessibilityIdentifier(prefix + "Label")
            entry("Usable amount in one pack", text: quantity, id: prefix + "Quantity")
            unitPicker("Pack unit", selection: unit, id: prefix + "Unit")
            PackConversionControl(packLabel: label.wrappedValue.isEmpty ? tr(title) : label.wrappedValue,
                                  sourceUnit: unit.wrappedValue, targetUnit: model.draft.unit,
                                  conversion: conversion, identifier: prefix + "Conversion")
            entry("Price for one pack (USD)", text: price, id: prefix + "Price", keyboard: .decimalPad)
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
            if dynamicTypeSize.isAccessibilitySize { accessibleEditRow }
            Section {
                Text(model.draft.item.isEmpty ? tr("One item") : model.draft.item).font(.title.bold())
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($resultFocused, equals: .summary)
                Text(tr("Item-only comparison")).font(.headline)
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
                if let summary = result.purchaseSummary {
                    ComparisonMetric(summary, style: .headline, id: "comparisonPurchaseSummary")
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
                        Task {
                            await model.save(in: app.store)
                            await app.refresh()
                            guard reviewing else { return }
                            if model.savedAt != nil { resultFocused = .saved }
                            else if model.error != nil { resultFocused = .error }
                        }
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
            Button(conversion == nil ? tr("Add ingredient conversion") : tr("Edit ingredient conversion")) {
                editing = true
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
            Form {
                Section {
                    amountField(unit: draft.sourceUnit, text: $draft.sourceLiteral, id: "conversion.source")
                    amountField(unit: draft.targetUnit, text: $draft.targetLiteral, id: "conversion.target")
                    TextField(tr("Label or measurement note (optional)"), text: $draft.sourceNote, axis: .vertical)
                        .focused($focusedField, equals: "conversion.note")
                        .accessibilityIdentifier("conversion.note")
                } header: { Text(verbatim: packLabel) } footer: {
                    Text(tr("Enter two equivalent amounts for this food from the package label, a recipe, or your own measurement."))
                }
                Section {
                    if showError {
                        Text(tr("Enter two positive amounts. Use a decimal or fraction and keep the source note brief."))
                            .foregroundStyle(Theme.warning)
                    }
                    Button(tr("Confirm conversion")) {
                        guard (try? draft.unitBasis()) != nil else { showError = true; return }
                        conversion = draft
                        dismiss()
                    }.accessibilityIdentifier("conversion.confirm")
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
    }

    private func amountField(unit: UnitOfMeasure, text: Binding<String>, id: String) -> some View {
        let label = message("Amount in %@", unit.displayName)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(Theme.secondary)
            TextField(label, text: text)
                .keyboardType(.numbersAndPunctuation)
                .focused($focusedField, equals: id)
                .accessibilityLabel(label).accessibilityIdentifier(id)
                .frame(minHeight: 44)
        }
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
