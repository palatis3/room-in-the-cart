import DeviceSurfaces
import CoreDomain
import LocalStore
import HouseholdClient
import SwiftUI

struct PantryReceiptEntry: View {
    @ObservedObject var model: PantryModel
    var initialSource: SourceMediaRecord? = nil
    var verifySource: @MainActor () async throws -> Void = {}
    @State private var aliases: [InventoryReceiptAlias] = []
    private struct AliasScope: Equatable {
        let merchant: String?
        let language: String?
        let state: InventoryState?
    }
    private var aliasScope: AliasScope {
        .init(merchant: draft?.merchant, language: draft?.language, state: model.snapshot?.state)
    }
    @State private var sharedSource: SharedReceiptItem?
    private struct AssistanceReview: Identifiable {
        let id: UUID
        let state: InventoryState
        let line: ReceiptImportDraft.Line
    }
    @State private var assistance: AssistanceReview?
    @State private var reviewedSourceImage: Data?
    @State private var fileSource = false
    @State private var scan = false
    @State private var draft: ReceiptImportDraft?
    @State private var rescan: ReceiptRescanPrompt?
    @State private var review: PantryReceiptReview?
    @State private var working = false
    @State private var message: String?
    @State private var savedLotIDs: Set<UUID>?
    @FocusState private var field: String?
    @State private var targetID = UUID()
    @AccessibilityFocusState private var resultFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let message {
                Text(message).accessibilityFocused($resultFocused).accessibilityIdentifier("receipt.status")
            }
            if let savedLotIDs {
                Button(pantryText("Done")) { dismiss() }
                let lots = model.snapshot?.lots.filter { savedLotIDs.contains($0.id) } ?? []
                if model.permitsReceiptSource, !lots.isEmpty {
                    Section {
                        if lots.count == 1 {
                            storageGuideLinks(lots)
                        } else {
                            DisclosureGroup(pantryText("Choose a saved food")) { storageGuideLinks(lots) }
                        }
                    } header: {
                        Text(helpText("Food storage guide"))
                    } footer: {
                        Text(pantryText("Choose a matching food and confirm its storage history to estimate a quality date range."))
                    }
                }
            } else if let review {
                Section(pantryText("Confirm receipt lines")) {
                    if let first = review.facts.first {
                        Text(first.merchant)
                        Text(first.purchaseDate, format: .dateTime.year().month().day())
                        if let reference = first.transactionReference { Text(reference) }
                    }
                    ForEach(review.facts) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).font(.headline)
                            Text(row.originalLine).font(.caption)
                            if let place = row.documentLine { Text(receiptProvenance(place)).font(.caption) }
                            if review.existing.contains(row.lineID) {
                                Text(pantryText("Previously saved on this receipt."))
                            } else if case .linked = row.stock {
                                Text(pantryText("Link evidence to the delivered batch. Its pantry count stays the same."))
                                if let lot = model.snapshot?.lots.first(where: { $0.id == row.lotID }) {
                                    Text(pantryFormat("Link delivery: %@ · %@", lot.name, String(lot.id.uuidString.suffix(8))))
                                }
                                Text(pantryFormat("Usable %@", pantryQuantity(row.usable)))
                            } else if case .added(let location) = row.stock {
                                Text(pantryFormat("Add %@ to %@", pantryQuantity(row.usable), pantryLocationName(location)))
                            }
                            Text(pantryFormat("Received %@", pantryQuantity(row.received)))
                            if let paid = row.paidLineTotal { Text(pantryFormat("Paid line total %@", receiptMoney(paid))) }
                            else { Text(pantryText("Paid price unknown")) }
                        }.accessibilityElement(children: .combine)
                    }
                    Text(pantryText("Saving receipt evidence does not post a payment."))
                    Button(pantryText("Save reviewed lines")) { commit(review) }.disabled(working || !model.canEdit)
                        .accessibilityIdentifier("receipt.commit")
                    Button(pantryText("Edit receipt lines")) { self.review = nil; message = nil }.disabled(working)
                }
            } else if let rescan, let proposed = draft {
                PantryReceiptRescanView(model: model, prompt: rescan) { decision in
                    var next = proposed
                    next.rescanDecision = decision
                    prepare(next)
                } edit: {
                    self.rescan = nil; draft?.rescanDecision = nil; message = nil
                }.id(rescan.basis).disabled(working)
            } else if let displayed = draft {
                // SwiftUI may read a field during removal of its form. Retain the
                // displayed value for that transition and ignore stale setters.
                let value = Binding(get: { draft ?? displayed }, set: { updated in
                    guard draft?.draftID == displayed.draftID else { return }
                    draft = updated
                })
                Section(pantryText("Receipt details")) {
                    TextField(pantryText("Store or branch"), text: Binding(get: { value.wrappedValue.merchant }, set: {
                        value.wrappedValue.clearAliases()
                        value.wrappedValue.merchant = $0
                    })).focused($field, equals: "merchant")
                    if model.supportsReceiptAliases {
                        ReceiptLanguagePicker(language: Binding(get: { value.wrappedValue.language }, set: {
                            value.wrappedValue.clearAliases()
                            value.wrappedValue.language = $0
                        }))
                    }
                    TextField(pantryText("Confirmed transaction reference, if printed"), text: value.reference).focused($field, equals: "reference")
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    ReceiptPurchaseDateFields(draft: value)
                }
                Text(pantryText("Select only food you received. Leave fees, discounts, nonfood and unreadable lines skipped."))
                ForEach(displayed.lines) { line in
                    PantryReceiptLineEditor(line: captureDraftBinding(line, in: value.lines), lots: model.snapshot?.lots ?? [], purchases: model.recentPurchases, aliases: aliases.filter {
                        InventoryReceiptAlias.key($0.merchant) == InventoryReceiptAlias.key(displayed.merchant) && $0.language == displayed.language && ReceiptImportDraft.containsWording($0.wording, in: line.original)
                    }, receiptLanguage: displayed.language, matchesCurrent: {
                        model.permitsReceiptSource && draft?.draftID == displayed.draftID &&
                            draft?.merchant == displayed.merchant && draft?.language == displayed.language &&
                            draft?.lines.first(where: { $0.id == line.id }) == line
                    }, verifyAlias: { alias in
                        let current = try? await model.receiptAliases(merchant: displayed.merchant, language: displayed.language)
                        return current?.contains(alias) == true
                    }, assist: {
                        if let state = model.snapshot?.state, model.permitsReceiptSource {
                            assistance = AssistanceReview(id: displayed.draftID, state: state, line: line)
                        }
                    }, field: $field)
                }
                Button(pantryText("Review selected food")) {
                    prepare(value.wrappedValue)
                }.disabled(working || !model.canEdit || !value.dateConfirmed.wrappedValue || !value.lines.wrappedValue.contains { $0.treatment != .skip })
                .accessibilityIdentifier("receipt.review")
            } else {
                Section {
                    Button(pantryText("Read a receipt file")) { fileSource = true }.accessibilityIdentifier("receipt.document")
                    Button(pantryText("Scan or type receipt lines")) { scan = true }.accessibilityIdentifier("receipt.scan")
                    Text(pantryText("Check the printed wording first. Then confirm what arrived and how much is usable."))
                }
            }
            if working { ProgressView() }
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: field != nil, title: pantryText("Done"), identifier: "receipt.keyboardDone") { field = nil }
        .navigationTitle(pantryText("Review a receipt"))
        .privacySensitive()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Close")) { dismiss() }.disabled(working) } }
        .interactiveDismissDisabled(working || draft != nil)
        .task {
            if model.snapshot == nil { await model.load() }
            if draft == nil, savedLotIDs == nil, let initialSource {
                do {
                    try await verifySource()
                    accept(initialSource, fromSavedPickup: true)
                } catch { message = receiptError(error) }
            }
        }
        .onChange(of: model.snapshot?.state.workspaceID) { _, origin in
            if origin == nil { reviewedSourceImage = nil; assistance = nil; draft = nil; review = nil; rescan = nil; scan = false; fileSource = false; sharedSource = nil; savedLotIDs = nil }
        }
        .task(id: aliasScope) {
            let scope = aliasScope
            aliases = []
            guard model.supportsReceiptAliases, let merchant = scope.merchant, !merchant.isEmpty, let language = scope.language else { return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let matches = try? await model.receiptAliases(merchant: merchant, language: language)
            if !Task.isCancelled, scope == aliasScope { aliases = matches ?? [] }
        }
        .sheet(item: $assistance) { basis in
            AssistedCaptureLineReview(line: basis.line, sourceImage: reviewedSourceImage, authorized: { assistanceCurrent(basis) }, checkSource: verifySource) { suggestion, input, received in
                guard assistanceCurrent(basis), var current = draft,
                      let index = current.lines.firstIndex(where: { $0.id == basis.line.id }) else { throw PantryReceiptError.stale }
                try current.lines[index].applyAssisted(suggestion, request: input, reviewedLine: basis.line, useReceived: received)
                draft = current
            }
        }
        .sheet(isPresented: $fileSource) {
            if let state = model.snapshot?.state {
                NavigationStack {
                    PantryReceiptDocuments(model: model, target: .init(workspaceID: state.workspaceID, containerID: targetID,
                        objectID: targetID, revision: state.revision, kind: .receiptEvidence), authorize: {
                        model.permitsReceiptSource && model.snapshot?.state.workspaceID == state.workspaceID
                    }) { source, share in accept(source); sharedSource = share }
                }
            }
        }
        .sheet(isPresented: $scan) {
            if let state = model.snapshot?.state {
                NavigationStack {
                    ScanReviewView(kind: .receipt, target: .init(workspaceID: state.workspaceID, containerID: targetID,
                        objectID: targetID, revision: state.revision, kind: .receiptEvidence), authorize: {
                            model.canEdit && model.snapshot?.state.workspaceID == state.workspaceID
                        }) { result in
                            if case .evidence(let source) = result { accept(source) }
                        }
                }
            }
        }
    }

    private func storageGuideLinks(_ lots: [InventoryLot]) -> some View {
        ForEach(lots) { lot in
            NavigationLink {
                PantryLotStorageReference(model: model, lotID: lot.id, accessAllowed: model.permitsReceiptSource)
            } label: {
                LabeledContent(lot.name, value: pantryLocationName(lot.location))
            }
            .accessibilityIdentifier("receipt.storageGuide." + lot.id.uuidString)
        }
    }

    private func assistanceCurrent(_ basis: AssistanceReview) -> Bool {
        model.permitsReceiptSource && model.snapshot?.state == basis.state && draft?.draftID == basis.id &&
            draft?.lines.first(where: { $0.id == basis.line.id }) == basis.line
    }

    private func prepare(_ proposed: ReceiptImportDraft) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await verifySource()
                let result = try await model.reviewReceipt(proposed)
                guard model.permitsReceiptSource, draft?.draftID == proposed.draftID else { return }
                review = result; draft = proposed; rescan = nil; message = nil
            } catch let prompt as ReceiptRescanPrompt {
                guard model.permitsReceiptSource, draft?.draftID == proposed.draftID else { return }
                rescan = prompt
                message = proposed.rescanDecision == nil ? nil : pantryText("Choose each saved line once. An additional line must be distinct.")
                resultFocused = true
            } catch {
                if receiptBasisChanged(error) { rescan = nil; draft?.rescanDecision = nil; await model.load() }
                if rescan != nil, case PantryReceiptError.changedEvidence = error {
                    message = pantryText("The printed wording, quantity, price or storage differs from the original. Open the original for corrections, edit your selections, or review a separate purchase.")
                } else { message = receiptError(error) }
                resultFocused = true
            }
        }
    }

    private func accept(_ source: SourceMediaRecord, fromSavedPickup: Bool = false) {
        guard model.canEdit, model.snapshot?.state.workspaceID == source.target.workspaceID else { return }
        do {
            draft = try ReceiptImportDraft(source: source, fromSavedPickup: fromSavedPickup, lots: model.snapshot?.lots ?? [])
            reviewedSourceImage = source.imageJPEG
            message = nil
        }
        catch { message = receiptError(error) }
    }
    private func commit(_ value: PantryReceiptReview) {
        working = true
        Task {
            defer { working = false }
            do {
                try await verifySource()
                try await model.saveReceipt(value)
                review = nil; draft = nil; reviewedSourceImage = nil
                savedLotIDs = Set(value.facts.map(\.lotID))
                message = value.batch == nil ? pantryText("These lines were already saved.") : pantryText("Reviewed receipt lines saved.")
                if let sharedSource {
                    do { try await model.finishSharedReceipt(sharedSource, committed: true) }
                    catch { message = pantryText("Food saved. Reopen shared receipt files to discard the staged copy.") }
                    self.sharedSource = nil
                }
            } catch {
                message = receiptError(error)
                if error is PantryReceiptError || (error as? ComparisonStoreError) == .staleInventory {
                    review = nil
                    await model.load()
                }
            }
            resultFocused = true
        }
    }
}

struct ReceiptPurchaseDateFields: View {
    @Binding var draft: ReceiptImportDraft

    var body: some View {
        if let printed = draft.printedDate {
            LabeledContent(pantryText("Date wording on the receipt"), value: printed.wording)
        } else {
            Text(pantryText("Choose the purchase date from your receipt. An unclear date needs your review."))
        }
        DatePicker(pantryText("Purchase date"), selection: $draft.selectedPurchaseDate, in: ...Date(), displayedComponents: .date)
        Toggle(pantryText("I checked the purchase date."), isOn: $draft.dateConfirmed)
    }
}

struct PantryReceiptLineEditor: View {
    @Binding var line: ReceiptImportDraft.Line
    let lots: [InventoryLot]
    let purchases: [PantryRecentPurchase]
    let aliases: [InventoryReceiptAlias]
    let receiptLanguage: String
    let matchesCurrent: @MainActor () -> Bool
    let verifyAlias: @MainActor (InventoryReceiptAlias) async -> Bool
    var assist: (() -> Void)? = nil
    var householdDeliveries: [HouseholdPantryPage.Lot] = []
    var field: FocusState<String?>.Binding

    private func label(_ lot: InventoryLot) -> String {
        PantryReceiptDelivery.label(for: lot, purchase: purchases.first { $0.id == lot.id })
    }
    var body: some View {
        Section {
            Text(line.original).font(.headline)
            if let printed = line.printed {
                switch printed.kind {
                case .adjustment: Text(pantryText("Charge, credit or receipt summary. This line starts skipped.")).font(.caption)
                case .date: Text(pantryText("Receipt date wording. This line starts skipped.")).font(.caption)
                case .unclear: Text(pantryText("Unclear printed line. Check the original wording before using it.")).font(.caption)
                case .item:
                    if printed.uncertain { Text(pantryText("Some printed fields are unclear. Review them or leave the price unknown.")).font(.caption) }
                }
            }
            if let assist {
                Button(pantryText("Help with this line"), action: assist)
                    .accessibilityIdentifier("receipt.assistance.\(line.ordinal)")
            }
            Picker(pantryText("Receipt line action"), selection: $line.treatment) {
                Text(pantryText("Skip this line")).tag(ReceiptImportDraft.Treatment.skip)
                Text(pantryText("Add a separate physical batch")).tag(ReceiptImportDraft.Treatment.add)
                ForEach(lots.filter { PantryReceiptDelivery.fragment(of: $0) != nil }) { lot in
                    Text(label(lot))
                        .tag(ReceiptImportDraft.Treatment.link(lot.id))
                }
                ForEach(householdDeliveries) { lot in
                    Text(pantryFormat("Link delivery: %@ · %@", lot.foodName, String(lot.id.uuidString.suffix(8))))
                        .tag(ReceiptImportDraft.Treatment.link(lot.id))
                }
            }
            .onChange(of: line.treatment) { _, _ in line.clearAlias() }
            .accessibilityIdentifier("receipt.action.\(line.ordinal)")
            if line.treatment != .skip {
                let visible = aliases.filter { alias in
                    if case .link(let lotID) = line.treatment { return lots.contains { $0.id == lotID && $0.foodID == alias.foodID } }
                    return true
                }
                ForEach(visible) { alias in
                    Button(pantryFormat("Use saved product %@ for %@", alias.product, alias.wording)) { line.use(alias) }
                }
                if !visible.isEmpty {
                    DuplicateAssistanceView(source: .init(id: line.id, text: line.original),
                        candidates: visible.map { .init(id: $0.id, text: $0.wording + " · " + $0.product) },
                        language: receiptLanguage, authorized: matchesCurrent) { id in
                            guard let alias = visible.first(where: { $0.id == id }), matchesCurrent(),
                                  await verifyAlias(alias), matchesCurrent() else { return }
                            line.use(alias)
                        }
                }
                if line.appliedAlias != nil {
                    Button(pantryText("Undo saved spelling")) { line.clearAlias() }
                }
                TextField(pantryText("Food name"), text: Binding(get: { line.name }, set: { line.clearAlias(); line.name = $0 })).focused(field, equals: "name-\(line.ordinal)")
                if let printed = line.printed, let quantity = printed.quantity, let unit = printed.unit {
                    LabeledContent(pantryText("Printed quantity"), value: quantity + " " + pantryUnit(unit))
                    Button(pantryText("I received the printed quantity")) { line.usePrintedQuantity() }
                        .accessibilityIdentifier("receipt.printedQuantity.\(line.ordinal)")
                }
                TextField(pantryText("Amount actually received"), text: $line.received).focused(field, equals: "received-\(line.ordinal)").accessibilityIdentifier("receipt.received.\(line.ordinal)").keyboardType(.numbersAndPunctuation)
                TextField(pantryText("Amount usable"), text: $line.usable).focused(field, equals: "usable-\(line.ordinal)").accessibilityIdentifier("receipt.usable.\(line.ordinal)").keyboardType(.numbersAndPunctuation)
                Picker(pantryText("Unit"), selection: $line.unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) } }
                if line.treatment == .add {
                    if let storage = line.printed?.storage {
                        LabeledContent(pantryText("Suggested storage to check"), value: pantryLocationName(storage))
                    } else { Text(pantryText("Choose where you put this food. The initial selection is cupboard.")).font(.caption) }
                    Picker(pantryText("Storage"), selection: $line.location) {
                        ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                    }.accessibilityIdentifier("receipt.storage.\(line.ordinal)")
                }
                if let printed = line.printed, let amount = printed.amount, let wording = printed.priceWording, line.documentLine?.stage != .order {
                    LabeledContent(pantryText("Possible printed line total"), value: wording)
                    Button(pantryText("I paid this line total in USD")) { line.paid = amount }
                        .accessibilityIdentifier("receipt.printedPrice.\(line.ordinal)")
                }
                TextField(pantryText("Confirmed paid line total in USD, optional"), text: $line.paid).focused(field, equals: "paid-\(line.ordinal)").keyboardType(.decimalPad)
            }
        }
    }
}

private func receiptBasisChanged(_ error: Error) -> Bool {
    if case PantryReceiptError.stale = error { return true }
    return (error as? ComparisonStoreError) == .staleInventory
}

private func receiptError(_ error: Error) -> String {
    if (error as? ComparisonStoreError) == .payloadTooLarge { return pantryText("This receipt exceeds the local comparison limit. Open Receipt history to inspect the saved lines.") }
    if error is ScanFailure { return pantryText("This saved source is unavailable. Reopen the receipt in its private workspace.") }
    if case PantryReceiptError.changedEvidence = error { return pantryText("This receipt line already has different confirmed evidence. Open Receipt history to review it.") }
    if case PantryReceiptError.stale = error { return pantryText("The pantry changed. Refresh and review the receipt again.") }
    if (error as? ComparisonStoreError) == .staleInventory { return pantryText("The pantry changed. Refresh and review the receipt again.") }
    return pantryText("Check the store, purchase date, food, received amount, usable amount and optional paid total.")
}

func receiptMoney(_ price: Money) -> String {
    (Decimal(price.minorUnits) / 100).formatted(.currency(code: price.currency.rawValue))
}

struct PantryReceiptHistory: View {
    @ObservedObject var model: PantryModel
    var receiptID: UUID? = nil
    var permittedLines: Set<UUID>? = nil
    @State private var lastReadID: UUID?
    @State private var facts: [ReceiptAcquisition] = []
    @State private var hasMore = true
    @State private var busy = false
    @State private var message: String?
    @State private var learning: ReceiptAcquisition?
    @State private var correcting: ReceiptAcquisition?
    @State private var reviewedState: InventoryState?
    @State private var price = ""
    @State private var correctionMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let message { Text(message) }
            if facts.isEmpty && !busy && !hasMore { Text(pantryText("No confirmed receipt lines yet.")) }
            ForEach(facts) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.name).font(.headline)
                    Text(row.merchant + " · " + row.purchaseDate.formatted(date: .abbreviated, time: .omitted))
                    Text(row.originalLine)
                    if let place = row.documentLine { Text(receiptProvenance(place)) }
                    Text(pantryFormat("Received %@", pantryQuantity(row.received)))
                    if let paid = row.paidLineTotal { Text(pantryFormat("Paid line total %@", receiptMoney(paid))) }
                    else { Text(pantryText("Paid price unknown")) }
                    Text(pantryFormat("Receipt revision %@", String(row.revision)))
                    if model.supportsReceiptAliases {
                        Button(pantryText("Remember this product spelling")) { learning = row }
                            .buttonStyle(.borderless).disabled(!model.canEdit || busy)
                    }
                    Button(pantryText("Correct this paid total")) {
                        Task {
                            do {
                                correcting = try await model.latestReceiptRevision(row)
                                price = ""; correctionMessage = nil; reviewedState = model.snapshot?.state
                            } catch { message = receiptError(error) }
                        }
                    }.buttonStyle(.borderless).disabled(!model.canEdit || busy)
                }
            }
            if hasMore { Button(pantryText("Load receipt lines")) { Task { await loadPage() } }.disabled(busy) }
        }
        .privacySensitive()
        .onChange(of: model.snapshot?.state.workspaceID) { _, scope in
            if scope == nil { facts = []; lastReadID = nil; learning = nil; correcting = nil; price = ""; hasMore = false }
        }
        .navigationTitle(pantryText("Receipt history"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Done")) { dismiss() } } }
        .task { await loadPage() }
        .sheet(item: $learning) { original in
            NavigationStack { PantryReceiptAliasEntry(model: model, source: original) }
        }
        .sheet(item: $correcting) { original in
            NavigationStack {
                Form {
                    if let correctionMessage { Text(correctionMessage) }
                    Text(original.name)
                    Text(pantryFormat("Receipt revision %@", String(original.revision)))
                    if let current = original.paidLineTotal { Text(pantryFormat("Paid line total %@", receiptMoney(current))) }
                    else { Text(pantryText("Paid price unknown")) }
                    Text(original.merchant + " · " + original.purchaseDate.formatted(date: .abbreviated, time: .omitted))
                    TextField(pantryText("Corrected paid line total in USD"), text: $price).keyboardType(.decimalPad)
                    Text(pantryText("A correction adds a price revision. Pantry quantities and posted spending stay the same."))
                    Button(pantryText("Save price correction")) {
                        guard let state = reviewedState, let total = try? Money(decimal: price), total >= .zero else { return }
                        busy = true
                        Task {
                            do {
                                try await model.correctReceiptPrice(original, total: total, reviewedState: state)
                                message = pantryText("Price correction saved.")
                            } catch {
                                await model.load()
                                if model.canEdit, let latest = try? await model.latestReceiptRevision(original) {
                                    reviewedState = model.snapshot?.state
                                    correcting = latest
                                    correctionMessage = pantryText("Review the current price and your correction, then confirm again.")
                                    busy = false
                                    return
                                }
                                message = pantryText("The receipt changed or the price is invalid. Reopen the latest revision.")
                            }
                            correcting = nil; facts = []; lastReadID = nil; hasMore = true; busy = false
                            await loadPage()
                        }
                    }.disabled(busy || (try? Money(decimal: price)) == nil || (try? Money(decimal: price)) == original.paidLineTotal)
                }.navigationTitle(pantryText("Correct paid price"))
            }.interactiveDismissDisabled(busy)
        }
    }

    private func loadPage() async {
        guard !busy, hasMore else { return }
        busy = true
        defer { busy = false }
        do {
            let page = try await model.receiptHistory(after: lastReadID, receiptID: receiptID)
            lastReadID = page.last?.id
            facts.append(contentsOf: page.filter { permittedLines?.contains($0.lineID) ?? true })
            hasMore = page.count == 30
        } catch { message = receiptError(error) }
    }
}
