import DeviceSurfaces
import CoreDomain
import LocalStore
import HouseholdClient
import SwiftUI

struct PantryReceiptEntry: View {
    @ObservedObject var model: PantryModel
    var didFinishWithLot: (UUID) -> Void = { _ in }
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
    @State private var deliveryPurchases = false
    @State private var fileSource = false
    @State private var receiptTripReview = ReceiptTripReviewState()
    @State private var scan = false
    @State private var draft: ReceiptImportDraft?
    @State private var overlap: PutawayOverlap?
    @State private var rescan: ReceiptRescanPrompt?
    @State private var review: PantryReceiptReview?
    @State private var working = false
    @State private var message: String?
    @State private var expandedLines = Set<UUID>()
    @State private var amountCorrection: ReceiptAmountCorrection?
    @State private var correctionRequest: UUID?
    @State private var storeFocusRequest: UUID?
    @State private var receiptViewport = CGRect.null
    @State private var savedLotIDs: [UUID]?
    @State private var savedHeader: ReviewedReceiptHeader?
    @State private var savedPickupID: UUID?
    @FocusState private var field: String?
    @State private var targetID = UUID()
    @AccessibilityFocusState private var resultFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            form(proxy).onChange(of: correctionRequest) { _, request in
                guard request != nil, let issue = amountCorrection else { return }
                proxy.scrollTo(issue.focusKey, anchor: .center)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { receiptViewport = $0 }
        }
    }

    private func form(_ proxy: ScrollViewProxy) -> some View {
        WorkingForm {
            if let message {
                Text(message).accessibilityFocused($resultFocused).accessibilityIdentifier("receipt.status")
            }
            if let savedLotIDs {
                let byID = Dictionary(uniqueKeysWithValues: (model.snapshot?.lots ?? []).map { ($0.id, $0) })
                let lots = savedLotIDs.compactMap { byID[$0] }
                if let savedHeader {
                    let token = model.generation
                    ReceiptCouponReviewLink(source: .purchase(model, savedHeader), pickupID: savedPickupID, authorize: {
                        model.permitsReceiptSource && model.generation == token && self.savedHeader?.id == savedHeader.id
                    })
                }
                Button(pantryText("Done")) {
                    if model.permitsReceiptSource, let lot = lots.first { didFinishWithLot(lot.id) }
                    dismiss()
                }
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
                    if let putaway = review.putaway {
                        ReviewedReceiptHeading(header: putaway.header)
                        ForEach(putaway.decisions.filter { $0.lotID == nil }) { row in
                            PutawayDecisionLabel(row: row)
                        }
                    } else if let first = review.facts.first {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(first.merchant).font(.headline)
                            Text(first.purchaseDate, format: .dateTime.year().month().day())
                                .font(.subheadline).foregroundStyle(Theme.secondary)
                            if let reference = first.transactionReference { Text(reference).font(.subheadline) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(review.facts) { row in
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.name).font(.title3.weight(.semibold))
                                if review.putaway?.decisions.first(where: { $0.id == row.lineID })?.kind == .keptSome {
                                    Text(putawayText("Kept some")).font(.subheadline)
                                }
                                if review.existing.contains(row.lineID) {
                                    stockOutcome(pantryText("Previously saved on this receipt."), symbol: "checkmark.circle")
                                } else if case .linked = row.stock {
                                    stockOutcome(pantryText("Link evidence to the delivered batch. Its pantry count stays the same."), symbol: "link")
                                    if let lot = model.snapshot?.lots.first(where: { $0.id == row.lotID }) {
                                        Text(pantryFormat("Link delivery: %@ · %@", lot.name, String(lot.id.uuidString.suffix(8))))
                                    }
                                    Text(pantryFormat("Usable %@", pantryQuantity(row.usable)))
                                } else if case .added(let location) = row.stock {
                                    stockOutcome(pantryFormat("Add %@ to %@", pantryQuantity(row.usable), pantryLocationName(location)),
                                                 symbol: "shippingbox")
                                }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pantryFormat("Received %@", pantryQuantity(row.received)))
                                if let paid = row.paidLineTotal { Text(pantryFormat("Paid line total %@", receiptMoney(paid))) }
                                else { Text(pantryText("Paid price unknown")) }
                            }
                            .font(.subheadline)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pantryText("Printed line")).font(.caption)
                                Text(row.originalLine).font(.system(.subheadline, design: .monospaced))
                                if let place = row.documentLine { Text(receiptProvenance(place)).font(.caption) }
                            }
                            .foregroundStyle(Theme.secondary)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                    Text(pantryText("Saving receipt evidence does not post a payment."))
                        .font(.footnote).foregroundStyle(Theme.secondary)
                    Button(review.putaway.map { putawayActionTitle($0.decisions.filter { $0.kind == .stored || $0.kind == .keptSome }.filter { !review.existing.contains($0.id) }.count) } ?? pantryText("Confirm pantry changes")) { commit(review) }.buttonStyle(PrimaryAction()).disabled(working || !model.canEdit)
                        .accessibilityIdentifier("receipt.commit")
                    Button(pantryText("Edit receipt lines")) { self.review = nil; message = nil }.disabled(working)
                }
            } else if let overlap, let proposed = draft {
                PutawayOverlapReview(prompt: overlap) { choice in
                    var next = proposed
                    next.overlapChoices[overlap.basis] = choice
                    prepare(next)
                } edit: {
                    self.overlap = nil
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
                let storeIssue = receiptStoreIssue(displayed.merchant)
                if displayed.tracksPutaway {
                    ReceiptCouponReviewLink(source: .draftTerms, pickupID: displayed.savedPickup?.id, authorize: {
                        model.permitsReceiptSource && model.snapshot?.state.workspaceID == displayed.workspaceID &&
                            draft?.draftID == displayed.draftID
                    })
                }
                Section(pantryText("Receipt details")) {
                    let storeName = captureText("Store or receipt name (required)")
                    WorkingField(storeName) {
                        TextField(storeName, text: Binding(get: { value.wrappedValue.merchant }, set: {
                            value.wrappedValue.clearAliases()
                            value.wrappedValue.merchant = $0
                        }), prompt: Text("")).focused($field, equals: "merchant")
                            .accessibilityIdentifier("receipt.store")
                    }
                    .id("receipt.store")
                    .task(id: storeFocusRequest) {
                        guard let request = storeFocusRequest else { return }
                        await Task.yield()
                        guard !Task.isCancelled, storeFocusRequest == request,
                              model.canEdit, draft?.draftID == displayed.draftID else { return }
                        field = "merchant"
                        storeFocusRequest = nil
                    }
                    if model.supportsReceiptAliases {
                        ReceiptLanguagePicker(language: Binding(get: { value.wrappedValue.language }, set: {
                            value.wrappedValue.clearAliases()
                            value.wrappedValue.language = $0
                        }))
                    }
                    TextField(pantryText("Confirmed transaction reference, if printed"), text: value.reference).focused($field, equals: "reference")
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    ReceiptPurchaseDateFields(draft: value)
                        .id("receipt.purchaseDate")
                    if displayed.tracksPutaway {
                        WorkingField(putawayText("Paid receipt total in USD, if known")) {
                            TextField(putawayText("Paid receipt total in USD, if known"), text: value.receiptTotal)
                                .keyboardType(.decimalPad).focused($field, equals: "receiptTotal")
                                .accessibilityIdentifier("receipt.total")
                        }
                    }
                }
                if !model.receiptTrips.isEmpty {
                    NavigationLink {
                        ReceiptTripDifferenceReview(trips: model.receiptTrips, purchases: model.recentPurchases, aliases: aliases, draft: displayed, state: $receiptTripReview)
                    } label: { Text(captureText("Compare receipt with a planned shop")) }
                    .accessibilityIdentifier("receipt.tripDifferences")
                }
                Text(displayed.tracksPutaway
                     ? putawayText("Select the groceries you brought home intact. Review other lines individually. Only selected lines are saved.")
                     : pantryText("Select only food you received. Leave fees, discounts, nonfood and unreadable lines skipped."))
                let lots = model.snapshot?.lots ?? []
                let eligible = displayed.tracksPutaway ? displayed.lines.filter { $0.permitsIntactSelection(deliveries: lots) } : []
                let grouped = eligible.count > 1
                if grouped {
                    Section(putawayText("Intact groceries")) {
                        ForEach(eligible) { line in
                            ReceiptIntactToggle(line: captureDraftBinding(line, in: value.lines), lots: lots)
                        }
                    }
                }
                ForEach(displayed.lines) { line in
                    if grouped, eligible.contains(where: { $0.id == line.id }) {
                        let detailsLabel = putawayText("Edit amount or action") + " · " + line.name
                        DisclosureGroup(isExpanded: Binding(get: { expandedLines.contains(line.id) }, set: { open in
                            correctionRequest = nil
                            if open { expandedLines.insert(line.id) } else { expandedLines.remove(line.id) }
                        })) {
                            receiptEditor(line, value: value, displayed: displayed, grouped: true)
                        } label: {
                            Text(verbatim: detailsLabel)
                        }
                        .disclosureGroupStyle(LabeledFormDisclosureStyle(label: detailsLabel,
                            identifier: "receipt.details.\(line.ordinal)"))
                    } else {
                        receiptEditor(line, value: value, displayed: displayed, grouped: false)
                    }
                }
                if let storeIssue {
                    Button {
                        storeFocusRequest = UUID()
                        proxy.scrollTo("receipt.store", anchor: .center)
                    } label: {
                        Label(storeIssue, systemImage: "exclamationmark.circle").frame(minHeight: 44, alignment: .leading)
                    }.disabled(working || !model.canEdit)
                        .accessibilityIdentifier("receipt.storeIssue")
                } else if !displayed.dateConfirmed {
                    Button {
                        field = nil
                        proxy.scrollTo("receipt.purchaseDate", anchor: .center)
                    } label: {
                        Label(putawayText("Check the purchase date to continue."), systemImage: "exclamationmark.circle")
                            .frame(minHeight: 44, alignment: .leading)
                    }.disabled(working || !model.canEdit)
                        .accessibilityIdentifier("receipt.purchaseDateIssue")
                } else if displayed.selectedLines.isEmpty {
                    Text(putawayText("Choose what to include from at least one receipt line."))
                        .foregroundStyle(Theme.secondary)
                }
                Button(displayed.tracksPutaway ? putawayText("Review selected lines") : pantryText("Review selected food")) {
                    guard storeIssue == nil else { return }
                    prepare(value.wrappedValue)
                }.buttonStyle(PrimaryAction())
                    .disabled(working || !model.canEdit || storeIssue != nil || !displayed.dateConfirmed || displayed.selectedLines.isEmpty)
                .accessibilityIdentifier("receipt.review")
            } else {
                Section {
                    BrandScopeLabel(pantryText("Private receipt draft"), systemImage: "lock")
                    Text(putawayText("Check the printed lines, then choose what to record or put away."))
                        .foregroundStyle(Theme.secondary)
                    if let state = model.snapshot?.state {
                        ReceiptPhotoShortcuts(target: .init(workspaceID: state.workspaceID, containerID: targetID, objectID: targetID,
                            revision: state.revision, kind: .receiptEvidence), authorize: {
                                model.permitsReceiptSource && model.snapshot?.state.workspaceID == state.workspaceID
                            }, reviewsPrivateReceipt: true) { source in accept(source) }
                    }
                }
                Section {
                    Button { scan = true } label: {
                        Label(captureText("Type or paste receipt lines"), systemImage: "text.cursor")
                    }.accessibilityIdentifier("receipt.scan")
                    Button { fileSource = true } label: {
                        Label(pantryText("Read a receipt file"), systemImage: "doc")
                    }.accessibilityIdentifier("receipt.document")
                    if model.supportsReceiptAliases {
                        Button(pantryText("My delivery receipts")) { deliveryPurchases = true }
                            .accessibilityIdentifier("receipt.deliveryPurchases")
                    }
                }
            }
            if working { ProgressView() }
        }
        .onChange(of: draft?.lines) { _, rows in
            correctionRequest = nil
            if let issue = amountCorrection, rows?.first(where: { $0.id == issue.lineID })?.amountCorrection != issue {
                amountCorrection = nil
            }
        }
        .onChange(of: field) { _, focused in
            if focused != nil { correctionRequest = nil }
        }
        .onDisappear { correctionRequest = nil; storeFocusRequest = nil }
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
            if origin != draft?.workspaceID || origin == nil { reviewedSourceImage = nil; assistance = nil; draft = nil; review = nil; rescan = nil; overlap = nil; scan = false; fileSource = false; sharedSource = nil; savedLotIDs = nil; savedHeader = nil; savedPickupID = nil }
        }
        .onChange(of: draft?.draftID) { _, _ in receiptTripReview = .init() }
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
        .sheet(isPresented: $deliveryPurchases) {
            if let state = model.snapshot?.state {
                NavigationStack {
                    PrivateDeliveryReceiptsView(model: model, target: .init(workspaceID: state.workspaceID, containerID: targetID,
                        objectID: targetID, revision: state.revision, kind: .receiptEvidence)) { source, original, selected in
                            acceptDelivery(source, original: original, selected: selected)
                        }
                }
            }
        }
        .sheet(isPresented: $fileSource) {
            if let state = model.snapshot?.state {
                NavigationStack {
                    PantryReceiptDocuments(model: model, target: .init(workspaceID: state.workspaceID, containerID: targetID,
                        objectID: targetID, revision: state.revision, kind: .receiptEvidence), authorize: {
                        model.permitsReceiptSource && model.snapshot?.state.workspaceID == state.workspaceID
                    }, reviewsPrivateReceipt: true) { source, share in accept(source); sharedSource = share }
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

    private func receiptEditor(_ line: ReceiptImportDraft.Line, value: Binding<ReceiptImportDraft>,
                               displayed: ReceiptImportDraft, grouped: Bool) -> some View {
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
        }, permitsPutaway: displayed.tracksPutaway, grouped: grouped,
           correction: amountCorrection?.lineID == line.id ? amountCorrection : nil,
           correctionRequest: correctionRequest, correctionViewport: receiptViewport, focusCorrection: { request in
            guard correctionRequest == request, let issue = amountCorrection, issue.lineID == line.id,
                  field == nil, draft?.draftID == displayed.draftID, model.permitsReceiptSource else { return }
            correctionRequest = nil
            field = issue.focusKey
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: issue.text)
            }
        }, field: $field)
    }

    private func stockOutcome(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.action).accessibilityHidden(true)
        }
        .font(.body.weight(.semibold))
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
                review = result; draft = proposed; rescan = nil; overlap = nil; message = nil
            } catch let issue as ReceiptAmountCorrection {
                guard model.permitsReceiptSource, draft?.draftID == proposed.draftID,
                      draft?.lines.first(where: { $0.id == issue.lineID })?.amountCorrection == issue else { return }
                rescan = nil; overlap = nil; message = nil; field = nil
                expandedLines.insert(issue.lineID)
                amountCorrection = issue
                correctionRequest = UUID()
            } catch let prompt as PutawayOverlap {
                guard model.permitsReceiptSource, draft?.draftID == proposed.draftID else { return }
                draft = proposed; overlap = prompt; rescan = nil; message = nil
            } catch let prompt as ReceiptRescanPrompt {
                guard model.permitsReceiptSource, draft?.draftID == proposed.draftID else { return }
                overlap = nil; rescan = prompt
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

    private func acceptDelivery(_ source: SourceMediaRecord, original: PrivateDeliveryRevision, selected: Set<Int>) {
        accept(source)
        guard var current = draft, current.draftID == source.id else { return }
        current.tracksPutaway = false
        current.reference = original.order
        if let date = original.purchaseDate { current.purchaseDate = date }
        let reviewed = Dictionary(uniqueKeysWithValues: original.lines.filter { selected.contains($0.id) }.map { ($0.id, $0) })
        for index in current.lines.indices {
            guard let item = reviewed[current.lines[index].ordinal] else { continue }
            current.lines[index].location = item.disposition.storage ?? .fridge
            current.lines[index].treatment = .add
        }
        draft = current
    }

    private func accept(_ source: SourceMediaRecord, fromSavedPickup: Bool = false) {
        guard model.canEdit, model.snapshot?.state.workspaceID == source.target.workspaceID else { return }
        do {
            draft = try ReceiptImportDraft(source: source, fromSavedPickup: fromSavedPickup, lots: model.snapshot?.lots ?? [])
            draft?.tracksPutaway = !source.receiptLines.contains { $0.documentLine?.stage == .order }
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
                savedHeader = value.putaway?.header
                savedPickupID = draft?.savedPickup?.id
                review = nil; draft = nil; reviewedSourceImage = nil
                var seen = Set<UUID>()
                savedLotIDs = value.facts.map(\.lotID).filter { seen.insert($0).inserted }
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
    @Environment(\.locale) private var locale

    static func displayLocale(regionLocale: Locale, appLanguage: String?) -> Locale {
        guard let appLanguage,
              let language = Locale(identifier: appLanguage).language.languageCode,
              language != regionLocale.language.languageCode else { return regionLocale }
        var components = Locale.Components(locale: regionLocale)
        components.languageComponents.languageCode = language
        components.languageComponents.script = Locale(identifier: appLanguage).language.script
        return Locale(components: components)
    }

    var body: some View {
        if let printed = draft.printedDate {
            LabeledContent(pantryText("Date wording on the receipt"), value: printed.wording)
        } else {
            Text(pantryText("Choose the purchase date from your receipt. An unclear date needs your review."))
        }
        DatePicker(pantryText("Purchase date"), selection: $draft.selectedPurchaseDate, in: ...Date(), displayedComponents: .date)
            .environment(\.locale, Self.displayLocale(regionLocale: locale, appLanguage: Bundle.main.preferredLocalizations.first))
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
    var permitsPutaway = false
    var grouped = false
    var correction: ReceiptAmountCorrection? = nil
    var correctionRequest: UUID? = nil
    var correctionViewport: CGRect = .null
    var focusCorrection: ((UUID) -> Void)? = nil
    @State private var expanded = false
    var field: FocusState<String?>.Binding

    private func label(_ lot: InventoryLot) -> String {
        PantryReceiptDelivery.label(for: lot, purchase: purchases.first { $0.id == lot.id })
    }

    private func labeledField(_ title: String, text: Binding<String>, focusKey: String,
                              identifier: String? = nil, keyboard: UIKeyboardType = .default) -> some View {
        let request = correction?.focusKey == focusKey ? correctionRequest : nil
        let viewport = correctionViewport
        return VStack(alignment: .leading, spacing: 4) {
            if let correction, correction.focusKey == focusKey {
                Text(correction.text)
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("receipt.error." + correction.field.rawValue + "." + String(correction.ordinal))
            }
            WorkingField(title) {
                TextField(title, text: text, prompt: Text(""))
                    .keyboardType(keyboard).focused(field, equals: focusKey)
                    .accessibilityIdentifier(identifier ?? title)
                    .onGeometryChange(for: UUID?.self) { geometry in
                        // Form rows are lazy. Wait for the editable field to reach the receipt's visible frame.
                        guard let request else { return nil }
                        let frame = geometry.frame(in: .global)
                        guard !frame.isEmpty, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
                        return request
                    } action: { request in
                        if let request { focusCorrection?(request) }
                    }
            }
        }.id(focusKey)
    }

    var body: some View {
        if grouped { content }
        else { Section { content } }
    }

    @ViewBuilder private var content: some View {
        if ReceiptPrintedEvidence.isStandaloneAmount(line.original) {
            Text(line.original).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(putawayText("This amount has no linked item. Check the original receipt before using it."))
                .font(.subheadline).foregroundStyle(Theme.secondary)
        } else {
            editableContent
        }
    }

    @ViewBuilder private var editableContent: some View {
        if permitsPutaway {
            if !grouped, line.permitsIntactSelection(deliveries: lots), line.treatment == .skip || line.selectedIntact {
                ReceiptIntactToggle(line: $line, lots: lots)
            } else if !grouped { Text(verbatim: line.name).font(.headline) }
            DisclosureGroup(putawayText("Original wording and price")) {
                Text(verbatim: line.original).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text(line.paid.isEmpty ? line.printed?.priceWording ?? pantryText("Paid price unknown") :
                        pantryFormat("Paid line total %@", line.paid))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(pantryText("Printed line")).font(.subheadline).foregroundStyle(Theme.secondary)
                Text(line.original).font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(.vertical, 3)
        }
        if let printed = line.printed {
            switch printed.kind {
            case .adjustment: Text(pantryText("Charge, credit or receipt summary. This line starts skipped.")).font(.caption)
            case .date: Text(pantryText("Receipt date wording. This line starts skipped.")).font(.caption)
            case .unclear: Text(pantryText("Unclear printed line. Check the original wording before using it.")).font(.caption)
            case .item:
                if printed.uncertain { Text(pantryText("Some printed fields are unclear. Review them or leave the price unknown.")).font(.caption) }
            }
        }
        if permitsPutaway, line.documentLine?.stage != .order, CouponReceiptEvidence.isDiscountLine(line.original) {
            if line.treatment == .chargeOrReturn {
                Label(shelfText("Printed coupon line included"), systemImage: "checkmark.circle")
            } else {
                Button {
                    line.clearAlias()
                    line.selectedIntact = false
                    line.treatment = .chargeOrReturn
                } label: {
                    Text(shelfText("Include printed coupon line")).frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("receipt.savePrintedDiscount.\(line.ordinal)")
            }
        }
        if let assist {
            Button(pantryText("Help with this line"), action: assist)
                .accessibilityIdentifier("receipt.assistance.\(line.ordinal)")
        }
        Picker(pantryText("Receipt line action"), selection: $line.treatment) {
            Text(pantryText("Skip this line")).tag(ReceiptImportDraft.Treatment.skip)
            if !permitsPutaway || line.printed?.kind != .adjustment && line.printed?.kind != .date {
                Text(pantryText("Add a separate physical batch")).tag(ReceiptImportDraft.Treatment.add)
                if permitsPutaway {
                    Text(putawayText("Ate this")).tag(ReceiptImportDraft.Treatment.eaten)
                    Text(putawayText("Kept some")).tag(ReceiptImportDraft.Treatment.keptSome)
                    Text(putawayText("Missing or unusable")).tag(ReceiptImportDraft.Treatment.missing)
                }
            }
            if permitsPutaway {
                Text(putawayText("Fee, adjustment or return")).tag(ReceiptImportDraft.Treatment.chargeOrReturn)
            }
            ForEach(lots.filter { PantryReceiptDelivery.fragment(of: $0) != nil }) { lot in
                Text(label(lot))
                    .tag(ReceiptImportDraft.Treatment.link(lot.id))
            }
            ForEach(householdDeliveries) { lot in
                Text(pantryFormat("Link delivery: %@ · %@", lot.foodName, String(lot.id.uuidString.suffix(8))))
                    .tag(ReceiptImportDraft.Treatment.link(lot.id))
            }
        }
        .onChange(of: line.treatment) { _, next in
            line.clearAlias()
            if next != .add { line.selectedIntact = false }
            if next == .keptSome { line.usable = ""; line.location = .fridge }
        }
        .onChange(of: line.usable) { _, usable in
            if line.selectedIntact && usable != line.received { line.selectedIntact = false }
        }
        .onChange(of: line.received) { _, received in
            if line.selectedIntact && received != line.printed?.quantity { line.selectedIntact = false }
        }
        .onChange(of: line.unit) { _, unit in
            if line.selectedIntact && unit != line.printed?.unit { line.selectedIntact = false }
        }
        .accessibilityIdentifier("receipt.action.\(line.ordinal)")
        if line.treatment != .skip {
            Button(pantryText("Skip this line")) { line.treatment = .skip; line.clearAlias() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("receipt.skip.\(line.ordinal)")
            if line.selectedIntact && !grouped {
                Button(putawayText("Edit amount")) { expanded.toggle() }
                    .frame(minHeight: 44).accessibilityIdentifier("receipt.editAmount.\(line.ordinal)")
            }
            if !line.selectedIntact || grouped || expanded || correction != nil { detailFields }
        }
    }

    @ViewBuilder private var detailFields: some View {
        if line.treatment.recordsStock {
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
            labeledField(pantryText("Food name"), text: Binding(get: { line.name }, set: { line.clearAlias(); line.name = $0 }),
                         focusKey: "name-\(line.ordinal)")
            if let printed = line.printed, let quantity = printed.quantity, let unit = printed.unit {
                LabeledContent(pantryText("Printed quantity"), value: pantryPrintedQuantity(quantity, unit: unit))
                Button(pantryText("I received the printed quantity")) { line.usePrintedQuantity() }
                    .accessibilityIdentifier("receipt.printedQuantity.\(line.ordinal)")
            }
            labeledField(pantryText("Amount actually received"), text: $line.received, focusKey: "received-\(line.ordinal)",
                         identifier: "receipt.received.\(line.ordinal)", keyboard: .numbersAndPunctuation)
            labeledField(line.treatment == .keptSome ? putawayText("Usable portion taken home") : pantryText("Amount usable"), text: $line.usable, focusKey: "usable-\(line.ordinal)",
                         identifier: "receipt.usable.\(line.ordinal)", keyboard: .numbersAndPunctuation)
            Picker(pantryText("Unit"), selection: $line.unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pantryUnit($0)).tag($0) } }
            if permitsPutaway && line.needsPackReview {
                Toggle(putawayText("I checked the number of packs and the unit for these amounts."), isOn: $line.checkedPack)
                    .onChange(of: line.received) { _, _ in line.checkedPack = false }
                    .onChange(of: line.unit) { _, _ in line.checkedPack = false }
                    .onChange(of: line.usable) { _, _ in line.checkedPack = false }
            }
            if line.treatment == .add || line.treatment == .keptSome {
                if let storage = line.printed?.storage {
                    LabeledContent(pantryText("Suggested storage to check"), value: pantryLocationName(storage))
                } else if line.treatment == .keptSome { Text(putawayText("Choose where you put the remainder.")).font(.caption) }
                else { Text(pantryText("Choose where you put this food. The initial selection is cupboard.")).font(.caption) }
                Picker(putawayText("Destination in My Pantry"), selection: $line.location) {
                    ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                }.accessibilityIdentifier("receipt.storage.\(line.ordinal)")
            }
        } else {
            Text(putawayText("Saves receipt evidence only. No food goes into Pantry.")).font(.subheadline)
        }
        if let printed = line.printed, let amount = printed.amount, let wording = printed.priceWording, line.documentLine?.stage != .order {
            LabeledContent(pantryText("Possible printed line total"), value: wording)
            Button(pantryText("I paid this line total in USD")) { line.paid = amount }
                .accessibilityIdentifier("receipt.printedPrice.\(line.ordinal)")
        }
        labeledField(pantryText("Confirmed paid line total in USD, optional"), text: $line.paid,
                     focusKey: "paid-\(line.ordinal)", keyboard: line.treatment == .chargeOrReturn ? .numbersAndPunctuation : .decimalPad)
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
    var showsDone = true
    @State private var hasPutaway = false
    @State private var lastReadID: UUID?
    @State private var facts: [ReceiptAcquisition] = []
    @State private var hasMore = true
    @State private var busy = false
    @State private var newReceipt = false
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
            if busy && facts.isEmpty { ProgressView(pantryText("Working…")) }
            if hasPutaway, receiptID == nil, permittedLines == nil, model.canEdit {
                NavigationLink(putawayText("Reviewed purchase totals and line decisions")) {
                    PutawayHistory(model: model)
                }.accessibilityIdentifier("receipt.putawayHistory")
            }
            if facts.isEmpty && !hasPutaway && !busy && !hasMore && model.phase == .ready {
                Section {
                    Text(pantryText("No confirmed receipt lines yet.")).font(.headline)
                    if receiptID == nil, model.canEdit {
                        Button { newReceipt = true } label: { Label(pantryText("Review a receipt"), systemImage: pantryReceiptSymbol) }
                            .accessibilityIdentifier("receipt.history.start")
                    }
                }
            }
            ForEach(facts) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.name).font(.headline)
                    Text(row.merchant + " · " + row.purchaseDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                    Text(row.originalLine)
                        .font(.system(.body, design: .monospaced))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
                    if let place = row.documentLine { Text(receiptProvenance(place)) }
                    Text(pantryFormat("Received %@", pantryQuantity(row.received))).monospacedDigit()
                    Text(pantryFormat("Usable %@", pantryQuantity(row.usable))).monospacedDigit()
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
            if scope == nil { newReceipt = false; hasPutaway = false; facts = []; lastReadID = nil; learning = nil; correcting = nil; price = ""; hasMore = false }
        }
        .workingSurface()
        .navigationTitle(pantryText("Receipt history"))
        .toolbar {
            if showsDone { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Done")) { dismiss() } } }
        }
        .task {
            if model.phase == .idle { await model.load() }
            if model.phase == .ready { await loadPage() }
        }
        .sheet(isPresented: $newReceipt, onDismiss: {
            if model.canEdit {
                facts = []; lastReadID = nil; hasMore = true
                Task { await loadPage() }
            }
        }) {
            if model.phase == .ready, model.snapshot != nil { NavigationStack { PantryReceiptEntry(model: model) } }
        }
        .sheet(item: $learning) { original in
            NavigationStack { PantryReceiptAliasEntry(model: model, source: original) }
        }
        .sheet(item: $correcting) { original in
            NavigationStack {
                ReceiptPriceCorrection(original: original, price: $price, correctionMessage: correctionMessage, busy: busy) {
                    saveCorrection(original, total: $0)
                }
            }.interactiveDismissDisabled(busy)
        }
    }

    private func saveCorrection(_ original: ReceiptAcquisition, total: Money?) {
        guard !busy, let state = reviewedState, original.paidLineTotal != total,
              total.map({ $0 >= .zero }) ?? true else { return }
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
    }

    private func loadPage() async {
        guard !busy, hasMore else { return }
        busy = true
        defer { busy = false }
        do {
            if lastReadID == nil, receiptID == nil, permittedLines == nil {
                hasPutaway = try await !model.reviewedReceiptHeaders(after: nil).isEmpty
            }
            let page = try await model.receiptHistory(after: lastReadID, receiptID: receiptID)
            lastReadID = page.last?.id
            facts.append(contentsOf: page.filter { permittedLines?.contains($0.lineID) ?? true })
            hasMore = page.count == 30
        } catch { message = receiptError(error) }
    }
}

private struct ReceiptPriceCorrection: View {
    let original: ReceiptAcquisition
    @Binding var price: String
    let correctionMessage: String?
    let busy: Bool
    let save: (Money?) -> Void
    @State private var confirmingUnknown = false
    @FocusState private var priceFocused: Bool

    private var enteredTotal: Money? {
        guard let total = try? Money(decimal: price), total >= .zero else { return nil }
        return total
    }

    var body: some View {
        WorkingForm {
            if let correctionMessage { Text(correctionMessage) }
            Text(original.name)
            Text(pantryFormat("Receipt revision %@", String(original.revision)))
            if let current = original.paidLineTotal { Text(pantryFormat("Paid line total %@", receiptMoney(current))) }
            else { Text(pantryText("Paid price unknown")) }
            Text(original.merchant + " · " + original.purchaseDate.formatted(date: .abbreviated, time: .omitted))
            WorkingField(pantryText("Corrected paid line total in USD")) {
                TextField(pantryText("Corrected paid line total in USD"), text: $price, prompt: Text(""))
                    .keyboardType(.decimalPad).focused($priceFocused)
            }
            Text(pantryText("A correction adds a price revision. Pantry quantities and posted spending stay the same."))
            Button(pantryText("Save price correction")) {
                guard let total = enteredTotal else { return }
                priceFocused = false
                save(total)
            }.disabled(busy || enteredTotal == nil || enteredTotal == original.paidLineTotal)
            if original.paidLineTotal != nil {
                Button(pantryText("Mark paid total as unknown")) {
                    priceFocused = false
                    confirmingUnknown = true
                }.disabled(busy)
            }
        }
        .keyboardDoneAction(visible: priceFocused, title: pantryText("Done"), identifier: "receipt.correctionKeyboardDone") {
            priceFocused = false
        }
        .alert(pantryText("Mark paid total as unknown?"), isPresented: $confirmingUnknown) {
            Button(pantryText("Mark as unknown")) { save(nil) }
            Button(pantryText("Cancel"), role: .cancel) {}
        } message: {
            Text(pantryText("The earlier price stays in receipt history. Future price comparisons will omit this amount."))
        }.navigationTitle(pantryText("Correct paid price"))
    }
}

struct ReceiptTripReviewState {
    var trip: ReceiptTripPlan?
    var links: [UUID: ReceiptTripLink] = [:]
    var leftUnresolved = Set<UUID>()
}

struct ReceiptTripDifferenceReview: View {
    let trips: [ReceiptTripPlan]
    let purchases: [PantryRecentPurchase]
    var aliases: [InventoryReceiptAlias] = []
    let draft: ReceiptImportDraft
    @Binding var state: ReceiptTripReviewState
    @State private var editing: ReceiptImportDraft.Line?

    private var selectable: [ReceiptImportDraft.Line] {
        draft.lines.filter(\.canComparePurchase)
    }
    private func candidate(_ row: ReceiptImportDraft.Line, trip: ReceiptTripPlan) -> UUID? {
        let known = Set(aliases.filter { alias in
            InventoryReceiptAlias.key(alias.merchant) == InventoryReceiptAlias.key(draft.merchant) &&
            alias.language == draft.language && row.name == row.sourceName &&
            InventoryReceiptAlias.key(alias.wording) == InventoryReceiptAlias.key(row.printed?.name ?? row.original)
        }.map(\.foodID))
        return trip.suggestedLine(for: row, purchases: purchases, knownFood: known.count == 1 ? known.first : nil)
    }

    private func suggestions(_ trip: ReceiptTripPlan) -> [ReceiptTripLink] {
        let rows = selectable.compactMap { row in candidate(row, trip: trip).map { ($0, row) } }
        let byPlan = Dictionary(grouping: rows, by: { $0.0 })
        return trip.lines.compactMap { planned in
            guard let candidates = byPlan[planned.id], candidates.count == 1, let row = candidates.first?.1,
                  !state.leftUnresolved.contains(row.id), state.links[row.id] == nil,
                  !state.links.values.contains(where: { $0.portions[planned.id] != nil }),
                  planned.packages?.isEmpty != false, !trip.countsPacks, row.documentLine?.stage != .order,
                  let printed = row.printed, !printed.uncertain, let amount = printed.quantity, let unit = printed.unit,
                  let quantity = try? ComparisonModel.quantity(amount, unit),
                  let value = printed.amount, let money = try? Money(decimal: value),
                  let link = ReceiptTripLink(receiptLineID: row.id, printed: quantity, portions: [planned.id: quantity], printedTotal: money),
                  ReceiptTripLink.compare(planned, with: [row.id: link]) == .matched else { return nil }
            return link
        }
    }
    var body: some View {
        List {
            tripPicker
            if let trip = state.trip, trips.contains(trip) {
                comparisonSections(for: trip)
            } else if state.trip != nil {
                Text(captureText("This shop changed. Choose it again to compare the current plan."))
                Button(captureText("Clear comparison")) { state = .init() }
            }
        }
        .onAppear {
            if state.trip == nil, let source = draft.savedPickup, source.originID == draft.workspaceID,
               let trip = trips.first(where: { $0.id == source.id }) { state.trip = trip }
        }
        .navigationTitle(captureText("Receipt differences"))
        .sheet(item: $editing) { row in assignment(for: row) }
    }

    private var tripPicker: some View {
        let selection = Binding<UUID?>(get: { state.trip?.id }, set: { id in
            state = .init(trip: trips.first { $0.id == id })
        })
        return Picker(captureText("Planned shop"), selection: selection) {
            Text(captureText("Choose explicitly")).tag(nil as UUID?)
            ForEach(trips) { trip in
                let date = trip.date.formatted(date: .abbreviated, time: .shortened)
                let label = [trip.branch, date, String(trip.id.uuidString.suffix(6))].joined(separator: " · ")
                Text(label).tag(Optional(trip.id))
            }
        }
        .accessibilityIdentifier("receipt.tripPicker")
    }

    @ViewBuilder private func comparisonSections(for trip: ReceiptTripPlan) -> some View {
        let suggested = suggestions(trip)
        let suggestedIDs = Set(suggested.map(\.receiptLineID))
        let proposedPlans = Set(suggested.flatMap { $0.portions.keys })
        Section {
            Text(captureText("Compare only the pages you have. Missing evidence does not establish a shortage or overcharge. This review changes neither inventory nor spending."))
        }
        if draft.lines.contains(where: { $0.documentLine?.stage == .order }) {
            Text(captureText("An order confirmation describes the plan. Use a purchase receipt or final invoice to compare what was charged."))
        }
        unmatchedSection(trip, suggestedIDs: suggestedIDs)
        differencesSection(trip, proposedPlans: proposedPlans)
        suggestionsSection(trip, suggestedIDs: suggestedIDs)
        matchedSection(trip)
        reviewedSection
    }

    @ViewBuilder private func unmatchedSection(_ trip: ReceiptTripPlan, suggestedIDs: Set<UUID>) -> some View {
        let unmatched = selectable.filter { state.links[$0.id] == nil && !suggestedIDs.contains($0.id) }
        if !unmatched.isEmpty {
            Section(captureText("Receipt lines to review")) {
                ForEach(unmatched) { row in
                    Button { editing = row } label: {
                        VStack(alignment: .leading) {
                            Text(row.original)
                            if let id = candidate(row, trip: trip), let planned = trip.lines.first(where: { $0.id == id }) {
                                Text(captureText("Previously linked product") + " · " + planned.name).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func differencesSection(_ trip: ReceiptTripPlan, proposedPlans: Set<UUID>) -> some View {
        let differences = trip.lines.filter { !proposedPlans.contains($0.id) && ReceiptTripLink.compare($0, with: state.links) != .matched }
        if !differences.isEmpty {
            Section(captureText("Differences and unknowns")) {
                ForEach(differences) { planned in plannedRow(planned) }
            }
        }
    }

    @ViewBuilder private func suggestionsSection(_ trip: ReceiptTripPlan, suggestedIDs: Set<UUID>) -> some View {
        if !suggestedIDs.isEmpty {
            Section(captureText("Suggested exact matches")) {
                ForEach(selectable.filter { suggestedIDs.contains($0.id) }) { row in
                    Button { editing = row } label: {
                        VStack(alignment: .leading) {
                            Text(row.original)
                            if let id = candidate(row, trip: trip), let line = trip.lines.first(where: { $0.id == id }) {
                                Text(line.name + " · " + pantryQuantity(line.quantity)).font(.caption)
                            }
                        }
                    }
                }
                Button(captureText("Confirm these reviewed matches")) {
                    for link in suggestions(trip) { state.links[link.receiptLineID] = link }
                }
            }
        }
    }

    @ViewBuilder private func matchedSection(_ trip: ReceiptTripPlan) -> some View {
        let matched = trip.lines.filter { ReceiptTripLink.compare($0, with: state.links) == .matched }
        if !matched.isEmpty {
            DisclosureGroup(captureText("Confirmed matches") + " (" + String(matched.count) + ")") {
                ForEach(matched) { planned in plannedRow(planned) }
            }
        }
    }

    @ViewBuilder private var reviewedSection: some View {
        let reviewed = selectable.filter { state.links[$0.id] != nil }
        if !reviewed.isEmpty {
            DisclosureGroup(captureText("Edit reviewed receipt lines")) {
                ForEach(reviewed) { row in Button(row.original) { editing = row } }
            }
        }
    }

    @ViewBuilder private func assignment(for row: ReceiptImportDraft.Line) -> some View {
        if let trip = state.trip, trips.contains(trip) {
            NavigationStack {
                ReceiptTripAssignLine(row: row, trip: trip, existing: state.links[row.id],
                    suggestion: candidate(row, trip: trip)) { match in
                    guard trips.contains(trip), state.trip == trip else { return }
                    state.links[row.id] = match
                    if match == nil { state.leftUnresolved.insert(row.id) } else { state.leftUnresolved.remove(row.id) }
                    editing = nil
                }
            }
        }
    }

    private func tripQuantity(_ quantity: Quantity) -> String {
        if state.trip?.countsPacks == true { return captureText("Planned packs") + " · " + quantity.amount.description }
        return captureText("Planned amount") + " · " + pantryQuantity(quantity)
    }

    @ViewBuilder private func plannedRow(_ line: BasketLine) -> some View {
        let status = ReceiptTripLink.compare(line, with: state.links)
        VStack(alignment: .leading) {
            Text(line.name).font(.headline)
            Text(tripQuantity(line.quantity))
            if case .exact(let price) = line.expectedCost { Text(captureText("Planned line total") + " · " + receiptMoney(price)) }
            ForEach(selectable.filter { state.links[$0.id]?.portions[line.id] != nil }) { row in
                if let link = state.links[row.id], let portion = link.portions[line.id] {
                    Text(row.original + " · " + pantryQuantity(portion))
                    if let paid = link.printedTotal, link.portions.count == 1 {
                        Text(captureText("Receipt line total") + " · " + receiptMoney(paid))
                    }
                }
            }
            switch status {
            case .matched: Text(captureText("Product, quantity and line total match."))
            case .noEvidence: Text(captureText("No confirmed receipt link for this planned item."))
            case .incompatible: Text(captureText("The units are not comparable."))
            case .quantity: Text(captureText("The reviewed quantity differs from the planned quantity."))
            case .price: Text(captureText("The reviewed line total differs from the planned total."))
            case .priceUnknown: Text(captureText("Quantity matches. A comparable price is unknown."))
            }
        }
    }
}

private struct ReceiptTripAssignLine: View {
    let row: ReceiptImportDraft.Line
    let trip: ReceiptTripPlan
    let accept: (ReceiptTripLink?) -> Void
    @State private var primary: UUID?
    @State private var secondary: UUID?
    @State private var split: Bool
    @State private var unit: UnitOfMeasure
    @State private var amount: String
    @State private var secondAmount: String
    @State private var price: String
    @State private var checkedPacks: Bool
    @FocusState private var focus: String?
    @Environment(\.dismiss) private var dismiss

    init(row: ReceiptImportDraft.Line, trip: ReceiptTripPlan, existing: ReceiptTripLink?, suggestion: UUID?, accept: @escaping (ReceiptTripLink?) -> Void) {
        self.row = row; self.trip = trip; self.accept = accept
        _checkedPacks = State(initialValue: existing != nil)
        let parts = trip.lines.compactMap { line in existing?.portions[line.id].map { (line.id, $0) } }
        _primary = State(initialValue: parts.first?.0 ?? suggestion)
        _secondary = State(initialValue: parts.count == 2 ? parts[1].0 : nil)
        _split = State(initialValue: parts.count == 2)
        _unit = State(initialValue: trip.countsPacks ? .count : parts.first?.1.unit ?? row.printed?.unit ?? .count)
        let sum = try? parts.reduce(Rational.zero) { try $0.adding($1.1.amount) }
        _amount = State(initialValue: !parts.isEmpty ? sum?.description ?? "" : trip.countsPacks ? "" : row.printed?.quantity ?? "")
        _secondAmount = State(initialValue: parts.count == 2 ? parts[1].1.amount.description : "")
        if let money = existing?.printedTotal {
            _price = State(initialValue: NSDecimalNumber(decimal: Decimal(money.minorUnits) / 100).stringValue)
        } else { _price = State(initialValue: existing == nil ? row.printed?.amount ?? "" : "") }
    }

    private var selectedPacks: [BasketLine] {
        trip.lines.filter { line in (line.id == primary || (split && line.id == secondary)) && line.packages?.isEmpty == false }
    }

    private var proposed: ReceiptTripLink? {
        guard row.canComparePurchase, (selectedPacks.isEmpty && !trip.countsPacks) || checkedPacks else { return nil }
        guard let primary, let total = try? ComparisonModel.quantity(amount, unit), total.amount > .zero else { return nil }
        var portions = [primary: total]
        if split {
            guard let secondary, secondary != primary, let other = try? ComparisonModel.quantity(secondAmount, unit),
                  other.amount > .zero, let remaining = try? total.amount.subtracting(other.amount), remaining > .zero else { return nil }
            portions[primary] = Quantity(amount: remaining, unit: unit, originalLiteral: remaining.description)
            portions[secondary] = other
        }
        let entry = price.trimmingCharacters(in: .whitespacesAndNewlines)
        let money = try? Money(decimal: entry)
        guard entry.isEmpty || money != nil else { return nil }
        return .init(receiptLineID: row.id, printed: total, portions: portions, printedTotal: money)
    }
    @ViewBuilder private var quantityAndPrice: some View {
        TextField(captureText("Printed quantity"), text: $amount).focused($focus, equals: "amount")
        if trip.countsPacks {
            Text(captureText("Enter the number of comparable packs shown on the receipt."))
        } else {
            Picker(captureText("Printed unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { unit in Text(pantryUnit(unit)).tag(unit) }
            }
        }
        TextField(captureText("Printed line total in USD, if known"), text: $price).keyboardType(.decimalPad).focused($focus, equals: "price")
    }

    @ViewBuilder private var splitControls: some View {
        Toggle(captureText("Split the quantity between two planned lines"), isOn: $split)
        if split {
            Picker(captureText("Second planned product"), selection: $secondary) {
                Text(captureText("Choose explicitly")).tag(nil as UUID?)
                ForEach(trip.lines.filter { $0.id != primary }) { line in Text(line.name + " · " + pantryQuantity(line.quantity)).tag(Optional(line.id)) }
            }
            TextField(captureText("Quantity for the second line"), text: $secondAmount).focused($focus, equals: "split")
            Text(captureText("The rest goes to the first line. The price stays with the printed line."))
        }
    }

    @ViewBuilder private var packConfirmation: some View {
        if !selectedPacks.isEmpty || trip.countsPacks {
            ForEach(selectedPacks) { line in
                Text(line.name)
                ForEach(Array((line.packages ?? []).enumerated()), id: \.offset) { _, pack in
                    Text(String(pack.count) + " × " + pack.amountPerPack.description + " " + pantryUnit(pack.unit))
                }
            }
            Toggle(captureText("I checked the pack sizes and converted the receipt quantity to the chosen unit."), isOn: $checkedPacks)
        }
    }

    var body: some View {
        WorkingForm {
            Text(row.original).font(.headline)
            Text(captureText("Choose only a planned product you can verify from the receipt. Leave possible substitutions unresolved."))
            Picker(captureText("Planned product"), selection: $primary) {
                Text(captureText("Choose explicitly")).tag(nil as UUID?)
                ForEach(trip.lines) { line in Text(line.name + " · " + pantryQuantity(line.quantity)).tag(Optional(line.id)) }
            }
            quantityAndPrice
            splitControls
            packConfirmation
            Button(captureText("Confirm product and amount")) { if let proposed { accept(proposed) } }.disabled(proposed == nil)
            Button(captureText("Leave line unresolved")) { accept(nil) }
        }
        .onChange(of: primary) { _, _ in checkedPacks = false }
        .onChange(of: secondary) { _, _ in checkedPacks = false }
        .onChange(of: split) { _, _ in checkedPacks = false }
        .onChange(of: unit) { _, _ in checkedPacks = false }
        .navigationTitle(captureText("Review product link"))
        .keyboardDoneAction(visible: focus != nil, title: captureText("Done"), identifier: "receipt.differenceDone") { focus = nil }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captureText("Cancel")) { dismiss() } } }
    }
}
