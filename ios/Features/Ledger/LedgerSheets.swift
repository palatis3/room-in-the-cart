import SwiftUI
import CoreDomain

struct LedgerImportView: View {
    @ObservedObject var model: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    let shopID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var original = ""
    @State private var preview: StagedListImport?
    @State private var choices: [UUID: String] = [:]
    @State private var source: ImportSource = .typed
    @State private var importID = UUID()
    @State private var captured: ReviewedCapture?
    @State private var captureBinding: LedgerCaptureBinding?
    @State private var capturePresentation: LedgerCapturePresentation?
    @FocusState private var originalFocused: Bool
    private enum Focus: Hashable { case preview, status }
    @AccessibilityFocusState private var focus: Focus?
    private var shop: ShoppingLedger? { model.workspace.shops.first { $0.id == shopID } }

    var body: some View {
        Form {
            if let preview {
                Section(ledgerText("Original wording")) {
                    Text(original).textSelection(.enabled).accessibilityFocused($focus, equals: .preview)
                    if let data = captured?.previewImageData ?? captured?.sourceImageData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                            .accessibilityLabel(captureText("Selected source photo"))
                    }
                }
                Section {
                    let rows = Binding<[StagedImportLine]>(get: {
                        guard let current = self.preview, current.id == preview.id else { return [] }
                        return current.lines
                    }, set: { updated in
                        guard self.preview?.id == preview.id else { return }
                        self.preview?.lines = updated
                    })
                    ForEach(preview.lines) { row in
                        LedgerImportRowView(line: captureDraftBinding(row, in: rows),
                                            matches: matches(for: row, preview: preview),
                                            choice: Binding(get: { choices[row.id] ?? "" }, set: { setChoice($0, for: row) }),
                                            onEdited: { refreshMatches(changedID: row.id) })
                    }
                } header: { Text(ledgerText("Review every line")) } footer: {
                    Text(ledgerText("Merge confirms the same need. Add amount keeps an additional contribution. Unresolved amounts remain visibly unknown."))
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    Button(ledgerText("Add reviewed list")) {
                        Task {
                            guard captured == nil || captureAuthorized else {
                                model.error = captureText("This capture belongs to an earlier workspace or list revision. Review it again before adding anything.")
                                focus = .status; return
                            }
                            let decisions = Dictionary(uniqueKeysWithValues: preview.lines.map { row in
                                (row.id, resolution(choices[row.id] ?? "new"))
                            })
                            if await model.editShop(key: "import-\(preview.id)", shopID: shopID, { try $0.commitImport(preview, decisions: decisions) }) {
                                dismiss()
                            } else { focus = .status }
                        }
                    }.buttonStyle(PrimaryAction()).disabled(model.saving || !allDecided(preview))
                        .accessibilityIdentifier("ledgerCommitImport")
                    if captured != nil {
                        Button(captureText("Edit captured fields")) { beginCapture() }
                            .disabled(model.saving || model.hasPendingSave || !captureAuthorized)
                    } else {
                        Button(ledgerText("Edit original text")) { self.preview = nil; choices = [:]; importID = UUID() }
                            .disabled(model.saving || model.hasPendingSave)
                    }
                }
            } else {
                Section {
                    Text(ledgerText("One item per line. For example: 12 wraps or 2 kg rice."))
                    TextEditor(text: $original).frame(minHeight: 180)
                        .focused($originalFocused)
                        .accessibilityLabel(ledgerText("List to review")).accessibilityIdentifier("ledgerImportText")
                    PasteButton(payloadType: String.self) { values in
                        original = values.joined(separator: "\n")
                        source = .paste
                    }.accessibilityLabel(ledgerText("Paste list"))
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    Button(captureText("Capture and review fields")) { beginCapture() }
                        .disabled(model.saving || model.hasPendingSave || liveCaptureBinding == nil)
                        .accessibilityIdentifier("ledger.capture")
                    Text(captureText("Capture is for this private list. Guest changes use the dinner preview.")).font(.footnote)
                    Button(ledgerText("Review list")) {
                        guard let shop else { return }
                        originalFocused = false
                        let staged = shop.stageImport(text: original, source: source, importID: importID)
                        preview = staged
                        choices = Dictionary(uniqueKeysWithValues: staged.lines.filter { $0.duplicateLineIDs.isEmpty }.map { ($0.id, "new") })
                        focus = .preview
                    }.buttonStyle(PrimaryAction()).disabled(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ledgerReviewImport")
                }
            }
            Section { LedgerSaveStatus(model: model, onRetried: { dismiss() }).accessibilityFocused($focus, equals: .status) }
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Bring the list"))
            .keyboardDoneAction(visible: originalFocused, title: ledgerText("Done")) { originalFocused = false }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
            .sheet(item: $capturePresentation) { presentation in
                let binding = presentation.binding
                NavigationStack {
                    CaptureReviewView(initialText: presentation.text, initialSource: presentation.source, localeIdentifier: binding.localeIdentifier,
                        destination: presentation.destination, existingCapture: presentation.reviewed,
                        correctionScope: CaptureCorrectionScope(profileID: "local:" + binding.workspaceID.uuidString, localeIdentifier: binding.localeIdentifier),
                        authorize: { liveCaptureBinding == binding }, onReviewed: { receiveCapture($0, binding: binding) })
                }
            }
            .onChange(of: liveCaptureBinding) { _, current in
                if let binding = capturePresentation?.binding ?? captureBinding, current != binding { invalidateCapture() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { invalidateCapture() } }
    }

    private var liveCaptureBinding: LedgerCaptureBinding? {
        guard access.unlocked, !household.locked, model.ready,
              !model.hasPendingLedgerDeletion, let workspaceID = model.sourceWorkspaceID,
              let shop, model.workspace.selectedShopID == shopID else { return nil }
        if let projection = household.projection {
            guard household.identity != nil, projection.enrolled, ["shopper", "organizer"].contains(projection.role) else { return nil }
        } else if household.identity != nil { return nil }
        return LedgerCaptureBinding(workspaceID: workspaceID, shopID: shopID, revision: shop.revision,
            actorID: access.localActorID, subject: household.identity?.subject,
            householdID: household.projection?.household.id, memberID: household.projection?.memberId,
            role: household.projection?.role, localeIdentifier: locale.identifier)
    }
    private var captureAuthorized: Bool { captureBinding != nil && liveCaptureBinding == captureBinding }
    private func beginCapture() {
        guard let binding = liveCaptureBinding, let shop, !model.saving, !model.hasPendingSave else { return }
        originalFocused = false
        capturePresentation = LedgerCapturePresentation(binding: binding, destination: shop.title,
            text: original, source: source == .paste ? .paste : .typed, reviewed: captured)
    }
    private func receiveCapture(_ capture: ReviewedCapture, binding: LedgerCaptureBinding) {
        guard liveCaptureBinding == binding, !model.saving, !model.hasPendingSave, let shop else { return }
        do {
            let staged = try CaptureLedgerImport.stage(capture, in: shop)
            if staged.alreadyApplied { capturePresentation = nil; dismiss(); return }
            captureBinding = binding
            captured = capture; importID = capture.id; original = capture.originalText
            source = staged.preview.source; preview = staged.preview
            choices = Dictionary(uniqueKeysWithValues: staged.preview.lines.filter { $0.duplicateLineIDs.isEmpty }.map { ($0.id, "new") })
            capturePresentation = nil; focus = .preview; model.error = nil
        } catch {
            model.error = captureText("Review each item. Use a positive amount or leave it explicitly unknown; pack counts must be whole numbers.")
            focus = .status
        }
    }
    private func invalidateCapture() {
        guard capturePresentation != nil || captureBinding != nil else { return }
        capturePresentation = nil; captured = nil; captureBinding = nil
        preview = nil; choices = [:]; original = ""; importID = UUID()
    }

    private func allDecided(_ preview: StagedListImport) -> Bool {
        !preview.lines.isEmpty && preview.lines.allSatisfy { !(choices[$0.id] ?? "").isEmpty }
    }
    private func matches(for row: StagedImportLine, preview: StagedListImport) -> [ImportMatch] {
        let saved = (shop?.lines ?? []).filter { row.duplicateLineIDs.contains($0.id) }.map {
            ImportMatch(id: $0.id, name: ledgerFormat("Item %lld: %@", Int64($0.originalOrder + 1), $0.name))
        }
        let staged = preview.lines.enumerated().filter {
            row.duplicateLineIDs.contains($0.element.proposedLineID) && choices[$0.element.id] == "new"
        }.map {
            ImportMatch(id: $0.element.proposedLineID, name: ledgerFormat("Preview line %lld: %@", Int64($0.offset + 1), $0.element.name))
        }
        return saved + staged
    }
    private func setChoice(_ value: String, for row: StagedImportLine) {
        guard let preview, preview.lines.contains(where: { $0.id == row.id }) else { return }
        choices[row.id] = value
        if value != "new" {
            for other in preview.lines where choices[other.id]?.hasSuffix(":\(row.proposedLineID)") == true {
                choices[other.id] = ""
            }
        }
    }
    private func refreshMatches(changedID: UUID) {
        guard let shop, let preview, preview.lines.contains(where: { $0.id == changedID }) else { return }
        if preview.lines.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            choices[changedID] = ""
            return
        }
        do {
            let refreshed = try shop.refreshImportMatches(preview)
            for row in refreshed.lines {
                let old = preview.lines.first { $0.id == row.id }
                if row.id == changedID || old?.duplicateLineIDs != row.duplicateLineIDs {
                    choices[row.id] = row.duplicateLineIDs.isEmpty ? "new" : ""
                }
            }
            self.preview = refreshed
            model.error = nil
        } catch LedgerError.stalePreview {
            model.error = ledgerText("This pickup changed after your preview. Return to the original text and review it again before adding it.")
        } catch {
            choices[changedID] = ""
            model.error = ledgerText("Check the amounts, units and links. This change could not be applied; your saved pickup is unchanged.")
        }
    }
    private func resolution(_ value: String) -> ImportResolution {
        if value == "skip" { return .skip }
        let parts = value.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let id = UUID(uuidString: String(parts[1])) {
            if parts[0] == "merge" { return .mergeDuplicate(id) }
            if parts[0] == "add" { return .addToLine(id) }
        }
        return .addNew
    }
}

private struct LedgerCaptureBinding: Equatable {
    let workspaceID: UUID
    let shopID: UUID
    let revision: Int
    let actorID: UUID
    let subject: String?
    let householdID: String?
    let memberID: String?
    let role: String?
    let localeIdentifier: String
}

private struct LedgerCapturePresentation: Identifiable {
    let id = UUID()
    let binding: LedgerCaptureBinding
    let destination: String
    let text: String
    let source: CaptureSource
    let reviewed: ReviewedCapture?
}

private struct ImportMatch: Identifiable { let id: UUID; let name: String }

private struct LedgerImportRowView: View {
    @Binding var line: StagedImportLine
    let matches: [ImportMatch]
    @Binding var choice: String
    let onEdited: () -> Void
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    init(line: Binding<StagedImportLine>, matches: [ImportMatch], choice: Binding<String>, onEdited: @escaping () -> Void) {
        _line = line
        self.matches = matches
        _choice = choice
        self.onEdited = onEdited
        _amount = State(initialValue: line.wrappedValue.quantity.map { ledgerAmountInput($0.amount) } ?? "")
        _unit = State(initialValue: line.wrappedValue.quantity?.unit ?? .count)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(line.originalText).font(.caption).foregroundStyle(Theme.secondary)
            if let capture = line.capture {
                Text(line.name).font(.headline)
                if let quantity = line.quantity { Text(ledgerAmountInput(quantity.amount) + " " + quantity.unit.displayName) }
                if let count = capture.packCount { Text(captureText("Packs") + ": " + String(count)) }
                if let amount = capture.amountPerPack { Text(captureText("Usable amount per pack") + ": " + ledgerAmountInput(amount.amount) + " " + amount.unit.displayName) }
                Text(captureText("Purpose") + ": " + capture.purpose)
                Text(captureText("Destination") + ": " + capture.destination)
                if !line.exclusions.isEmpty { Text(captureText("Exclusions") + ": " + line.exclusions.joined(separator: "; ")) }
            } else {
            TextField(ledgerText("Item name"), text: $line.name, axis: .vertical)
            TextField(ledgerText("Amount, unknown if blank"), text: $amount).keyboardType(.decimalPad)
            Picker(ledgerText("Unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            }
            if line.quantity == nil {
                Label(ledgerText("Quantity unresolved"), systemImage: "questionmark.circle").foregroundStyle(Theme.warning)
                if let reason = line.unresolvedReason { Text(ledgerContributionNote(reason)).font(.footnote) }
            }
            if !matches.isEmpty {
                Text(ledgerText("A matching item is already listed. Is this the same need or an additional amount?"))
                    .font(.subheadline)
            }
            Picker(ledgerText("How to add this line"), selection: $choice) {
                if choice.isEmpty { Text(ledgerText("Choose how to add")).tag("") }
                Text(ledgerText("Add as a separate line")).tag("new")
                ForEach(matches, id: \.id) { match in
                    Text(ledgerFormat("Merge same need: %@", match.name)).tag("merge:\(match.id)")
                    Text(ledgerFormat("Add amount to: %@", match.name)).tag("add:\(match.id)")
                }
                Text(ledgerText("Skip this line")).tag("skip")
            }.pickerStyle(.menu)
        }.padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            .onChange(of: amount) { _, _ in updateQuantity() }
            .onChange(of: unit) { _, _ in updateQuantity() }
            .onChange(of: line.name) { _, _ in onEdited() }
    }
    private func updateQuantity() {
        line.quantity = try? LedgerEntry.quantity(amount, unit)
        line.unresolvedReason = line.quantity == nil ? "quantityUnknown" : nil
        onEdited()
    }
}

struct LedgerFactsView: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    @Environment(\.dismiss) private var dismiss
    @State private var basis: ShopBasis
    @State private var cap: String
    @State private var reserve: String
    @State private var fees: String
    @State private var hasRetailerPreview: Bool
    @State private var retailerTotal: String
    @State private var retailerSource: String
    @State private var retailerDate: Date
    @State private var includedCharges: String
    @State private var hasSlot: Bool
    @State private var slot: Date
    @State private var reviewing = false
    @State private var reviewedRevision: Int
    @State private var reviewedBase: ShopBasis
    @State private var validation: String?
    private enum Input: Hashable { case branch, timeZone, cap, reserve, fees, retailerTotal, retailerSource, includedCharges }
    @FocusState private var inputFocus: Input?
    init(model: LedgerModel, shop: ShoppingLedger) {
        self.model = model
        self.shop = shop
        _reviewedRevision = State(initialValue: shop.revision)
        _reviewedBase = State(initialValue: shop.basis)
        _basis = State(initialValue: shop.basis)
        _cap = State(initialValue: shop.basis.cap.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _reserve = State(initialValue: shop.basis.fixedReserve.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _fees = State(initialValue: shop.basis.knownFees.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _hasRetailerPreview = State(initialValue: shop.basis.retailerPreview != nil)
        _retailerTotal = State(initialValue: shop.basis.retailerPreview?.total.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? "")
        _retailerSource = State(initialValue: shop.basis.retailerPreview?.source ?? "")
        _retailerDate = State(initialValue: shop.basis.retailerPreview?.capturedAt ?? Date())
        _includedCharges = State(initialValue: shop.basis.retailerPreview?.includedCharges.joined(separator: ", ") ?? "")
        _hasSlot = State(initialValue: shop.basis.slot != nil)
        _slot = State(initialValue: shop.basis.slot ?? Date())
    }
    var body: some View {
        Form {
            if reviewing {
                Section(ledgerText("Previously saved")) { summary(reviewedBase) }
                Section(ledgerText("Proposed pickup details")) { summary(basis) }
                Section {
                    Text(ledgerText("Changing the store, mode, date or costs invalidates earlier pickup quotes. Review them again before relying on a total."))
                    Button(ledgerText("Save pickup details")) {
                        Task { if await model.editShop(key: "basis-\(shop.id)", shopID: shop.id, {
                            guard $0.revision == reviewedRevision else { throw LedgerError.stalePreview }
                            try $0.updateBasis(basis)
                        }) { dismiss() } }
                    }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("ledgerCommitFacts")
                    Button(ledgerText("Keep editing")) { reviewing = false }.disabled(model.saving || model.hasPendingSave)
                }
            } else {
                Section(ledgerText("Store and timing")) {
                    TextField(ledgerText("Store branch"), text: $basis.branch, axis: .vertical).accessibilityIdentifier("ledgerBranch")
                        .focused($inputFocus, equals: .branch)
                    Picker(ledgerText("How you will shop"), selection: $basis.mode) {
                        Text(FulfillmentMode.pickup.ledgerLabel).tag(FulfillmentMode.pickup)
                        Text(FulfillmentMode.delivery.ledgerLabel).tag(FulfillmentMode.delivery)
                        Text(FulfillmentMode.inStore.ledgerLabel).tag(FulfillmentMode.inStore)
                    }
                    Toggle(ledgerText("Set a pickup date and time"), isOn: $hasSlot)
                    if hasSlot {
                        DatePicker(ledgerText("Pickup date and time"), selection: $slot)
                            .environment(\.timeZone, TimeZone(identifier: basis.timeZoneIdentifier) ?? .current)
                    }
                    TextField(ledgerText("Time zone, for example America/New_York"), text: $basis.timeZoneIdentifier)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($inputFocus, equals: .timeZone)
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    TextField(ledgerText("Spending cap (USD, optional)"), text: $cap).keyboardType(.decimalPad)
                        .accessibilityIdentifier("ledgerCap")
                        .focused($inputFocus, equals: .cap)
                    Picker(ledgerText("What the cap covers"), selection: $basis.capScope) {
                        Text(BudgetScope.wholeShop.ledgerLabel).tag(BudgetScope.wholeShop)
                        Text(BudgetScope.dinnersOnly.ledgerLabel).tag(BudgetScope.dinnersOnly)
                        Text(BudgetScope.selectedItems.ledgerLabel).tag(BudgetScope.selectedItems)
                    }
                    Picker(ledgerText("How firm is this cap?"), selection: $basis.capFirmness) {
                        Text(ledgerText("Firm limit")).tag(CapFirmness.firm)
                        Text(ledgerText("Flexible limit")).tag(CapFirmness.flexible)
                    }
                    TextField(ledgerText("Fixed reserve (USD, optional)"), text: $reserve).keyboardType(.decimalPad)
                        .focused($inputFocus, equals: .reserve)
                    TextField(ledgerText("Known fees (USD, unknown if blank)"), text: $fees).keyboardType(.decimalPad)
                        .focused($inputFocus, equals: .fees)
                    Text(ledgerText("Currency: USD"))
                } header: { Text(ledgerText("Spending cap")) } footer: {
                    Text(ledgerText("A dinner-only cap does not cover the whole pickup. Missing prices and fees remain unknown."))
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    Toggle(ledgerText("Record a retailer preview"), isOn: $hasRetailerPreview)
                    if hasRetailerPreview {
                        TextField(ledgerText("Retailer total (USD, unknown if blank)"), text: $retailerTotal).keyboardType(.decimalPad)
                            .focused($inputFocus, equals: .retailerTotal)
                        TextField(ledgerText("Source of the retailer preview"), text: $retailerSource, axis: .vertical)
                            .focused($inputFocus, equals: .retailerSource)
                        DatePicker(ledgerText("When this preview was shown"), selection: $retailerDate)
                            .environment(\.timeZone, TimeZone(identifier: basis.timeZoneIdentifier) ?? .current)
                        TextField(ledgerText("Included charges, separated by commas"), text: $includedCharges, axis: .vertical)
                            .focused($inputFocus, equals: .includedCharges)
                        Text(ledgerText("This records what the retailer displayed. It is not a calculated whole-pickup quote."))
                    }
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    Button(ledgerText("Review pickup details")) { review() }
                        .buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("ledgerReviewFacts")
                }
            }
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Describe this pickup"))
            .keyboardDoneAction(visible: inputFocus != nil, title: ledgerText("Done"), identifier: "ledgerFactsKeyboardDone") { inputFocus = nil }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
    private func review() {
        inputFocus = nil
        do {
            guard TimeZone(identifier: basis.timeZoneIdentifier) != nil else {
                validation = ledgerText("Enter a valid time zone, such as America/New_York.")
                return
            }
            basis.cap = try ComparisonModel.money(cap)
            basis.fixedReserve = try ComparisonModel.money(reserve)
            basis.knownFees = try ComparisonModel.money(fees)
            if hasRetailerPreview {
                basis.retailerPreview = LedgerRetailerPreview(total: try ComparisonModel.money(retailerTotal), source: retailerSource,
                                                              capturedAt: retailerDate, includedCharges: includedCharges.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            } else { basis.retailerPreview = nil }
            basis.slot = hasSlot ? slot : nil
            try basis.validate()
            if let latest = model.workspace.shops.first(where: { $0.id == shop.id }) {
                reviewedRevision = latest.revision
                reviewedBase = latest.basis
            }
            validation = nil
            reviewing = true
        } catch { validation = ledgerText("Use a nonnegative USD amount with no more than two decimal places.") }
    }
    private func summary(_ value: ShopBasis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.branch.isEmpty ? ledgerText("Store not set") : value.branch)
            Text(value.mode.ledgerLabel)
            if let date = value.slot { Text(ledgerDate(date, zone: value.timeZoneIdentifier)) }
            else { Text(ledgerText("Date not set")); Text(value.timeZoneIdentifier) }
            if let cap = value.cap { Text("\(moneyText(cap)) · \(value.capScope.ledgerLabel)") }
            else { Text(ledgerText("No spending cap entered")) }
            Text(ledgerText(value.capFirmness == .firm ? "Firm limit" : "Flexible limit"))
            Text(ledgerFormat("Fixed reserve: %@", value.fixedReserve.map(moneyText) ?? ledgerText("Unknown")))
            Text(ledgerFormat("Fees: %@", value.knownFees.map(moneyText) ?? ledgerText("Unknown")))
            if let preview = value.retailerPreview {
                Text(ledgerFormat("Retailer preview: %@", preview.total.map(moneyText) ?? ledgerText("Unknown")))
                Text(preview.source)
                Text(ledgerDate(preview.capturedAt, zone: value.timeZoneIdentifier))
                Text(ledgerFormat("Included charges: %@", preview.includedCharges.joined(separator: ", ")))
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
