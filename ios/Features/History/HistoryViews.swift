import SwiftUI
import HouseholdClient

/// Manual, reviewed service records. No local ledger or imported archive is uploaded here.
struct HistoryEntryView: View {
    @ObservedObject var model: HistoryFeatureModel
    var chooseShop: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var section = "prices"
    @State private var editingObservation = false
    @State private var observationReference = ""
    @State private var useStartDate = false
    @State private var useEndDate = false
    @State private var startDate = Date().addingTimeInterval(-30 * 86400)
    @State private var endDate = Date()
    @State private var selectedShop = ""
    @State private var clearingRetry = false

    var body: some View {
        Form {
            Section {
                Text(HistoryCopy.text("Entered prices and period plans"))
                Text(HistoryCopy.text("These are household-entered records, not retailer prices, bank balances or verified savings."))
                    .font(.footnote)
            }
            if model.authorized {
                if let chooseShop, !editingObservation, model.periodDraft == nil, model.reviewed == nil, !model.hasUnresolvedWrite {
                    Button(HistoryCopy.text("Choose shared shop"), action: chooseShop).disabled(model.busy)
                }
                Picker(HistoryCopy.text("Records view"), selection: $section) {
                    Text(HistoryCopy.text("Price records")).tag("prices")
                    Text(HistoryCopy.text("Period budgets")).tag("periods")
                }.pickerStyle(.segmented)
                if model.hasUnresolvedWrite && model.pending == nil {
                    Section(HistoryCopy.text("A reviewed write still needs reconciliation")) {
                        Text(HistoryCopy.text("Refresh current access to reopen the original retry. Its private fields stay hidden until access is confirmed."))
                        Button(HistoryCopy.text("Refresh access for the saved retry")) { Task { await model.load() } }
                            .disabled(model.busy).frame(minHeight: 44)
                    }
                }
                if model.pending != nil { pendingSection }
                else if let reviewed = model.reviewed { reviewSection(reviewed) }
                else if section == "prices" {
                    if editingObservation && !model.hasUnresolvedWrite { observationEditor }
                    else { priceRecords }
                } else {
                    if model.periodDraft != nil && !model.hasUnresolvedWrite { periodEditor }
                    else { periodRecords }
                }
                if let notice = model.notice {
                    Section { Text(notice).accessibilityIdentifier("history.notice") }
                }
                if model.busy { ProgressView(HistoryCopy.text("Checking current access and records…")) }
            } else {
                Section {
                    Text(HistoryCopy.text("Open your adult household account to use these records. Each source still requires current shopper access."))
                    Button(HistoryCopy.text("Check access again")) { Task { await model.load() } }
                        .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle(HistoryCopy.text("Prices and period budgets"))
        .accessibilityIdentifier("history.home")
        .task { await model.load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                model.enforceRuntime()
                if !model.authorized { editingObservation = false; observationReference = "" }
            }
        }
        .onDisappear { model.invalidate(); editingObservation = false; observationReference = ""; clearingRetry = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.invalidate(); editingObservation = false; observationReference = "" }
            if phase == .active { Task { await model.load() } }
        }
        .confirmationDialog(HistoryCopy.text("Clear only the local retry record?"), isPresented: $clearingRetry, titleVisibility: .visible) {
            Button(HistoryCopy.text("Refresh status and clear local retry"), role: .destructive) {
                Task { await model.clearPendingAfterStatusReview(); if !model.hasUnresolvedWrite { editingObservation = false } }
            }
        } message: {
            Text(HistoryCopy.text("Current access and saved status will be checked first. Clearing a retry does not undo a write already received. Exact retry is the way to recover the original receipt."))
        }
        .onChange(of: useStartDate) { _, enabled in model.filter.from = enabled ? startDate : nil }
        .onChange(of: useEndDate) { _, enabled in model.filter.through = enabled ? endDate : nil }
        .onChange(of: startDate) { _, value in if useStartDate { model.filter.from = value } }
        .onChange(of: endDate) { _, value in if useEndDate { model.filter.through = value } }
    }

    @ViewBuilder private var priceRecords: some View {
        Section(HistoryCopy.text("Manual price evidence · Free")) {
            Button(HistoryCopy.text("Record an observed price")) { model.beginObservation(); editingObservation = true }
                .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("history.newObservation").disabled(!model.canBeginObservation)
            Text(HistoryCopy.text("Keep the pack, store branch, channel and fulfillment mode separate. Nothing is matched or converted automatically."))
                .font(.footnote)
            TextField(HistoryCopy.text("Saved observation reference"), text: $observationReference)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(HistoryCopy.text("Open saved observation")) { Task { await model.openObservation(observationReference) } }
                .disabled(model.busy || UUID(uuidString: observationReference) == nil).frame(minHeight: 44)
                .accessibilityIdentifier("history.openSavedObservation")
            ForEach(model.savedObservationIDs, id: \.self) { id in
                Button { Task { await model.openObservation(id) } } label: {
                    VStack(alignment: .leading) {
                        Text(HistoryCopy.text("Saved observation"))
                        Text(id).font(.caption).textSelection(.enabled)
                    }
                }.frame(minHeight: 44).disabled(model.busy)
            }
            if model.readableShopCursor != nil {
                Button(HistoryCopy.text("Check access for more saved records")) { Task { await model.loadReadableShops(more: true) } }
                    .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.moreSavedRecordAccess")
            }
        }
        if let observation = model.selectedObservation {
            Section(HistoryCopy.text("Saved observation")) { HistoryObservationDetails(observation: observation) }
        }
        Section(HistoryCopy.text("Price history · Household")) {
            Button(HistoryCopy.text("Load price history")) { Task { await model.loadPriceHistory() } }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.loadPrices")
            Text(HistoryCopy.text("History requires active membership and current access. Saved individual records remain available with Free access."))
                .font(.footnote)
            TextField(HistoryCopy.text("Filter by store"), text: $model.filter.store).accessibilityIdentifier("history.filterStore")
            TextField(HistoryCopy.text("Filter by branch"), text: $model.filter.branch).accessibilityIdentifier("history.filterBranch")
            Picker(HistoryCopy.text("Filter by channel"), selection: $model.filter.channel) {
                Text(HistoryCopy.text("All channels")).tag("")
                ForEach(HistoryPriceChannel.allCases, id: \.rawValue) { value in Text(HistoryCopy.channel(value.rawValue)).tag(value.rawValue) }
            }
            Picker(HistoryCopy.text("Filter by fulfillment"), selection: $model.filter.mode) {
                Text(HistoryCopy.text("All fulfillment modes")).tag("")
                ForEach(HistoryFulfillmentMode.allCases, id: \.rawValue) { value in Text(HistoryCopy.mode(value.rawValue)).tag(value.rawValue) }
            }
            Toggle(HistoryCopy.text("Filter from an evidence date"), isOn: $useStartDate)
            if useStartDate { DatePicker(HistoryCopy.text("Observed on or after"), selection: $startDate, displayedComponents: [.date, .hourAndMinute]) }
            Toggle(HistoryCopy.text("Filter through an evidence date"), isOn: $useEndDate)
            if useEndDate { DatePicker(HistoryCopy.text("Observed on or before"), selection: $endDate, displayedComponents: [.date, .hourAndMinute]) }
            Text(HistoryCopy.text("Filters apply only to loaded, authorized records. Load more to continue searching."))
                .font(.footnote)
            ForEach(model.filteredObservations, id: \.id) { observation in
                DisclosureGroup {
                    HistoryObservationDetails(observation: observation)
                    Button(HistoryCopy.text("Open this saved observation")) { Task { await model.openObservation(observation.id) } }
                        .disabled(model.busy).frame(minHeight: 44)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(observation.itemName).font(.headline)
                        Text(observation.packLabel)
                        Text(observation.store + " · " + observation.branch)
                        Text(HistoryCopy.channel(observation.channel.rawValue) + " · " + HistoryCopy.mode(observation.mode.rawValue)).font(.caption)
                    }
                }
            }
            if model.observationCursor != nil {
                Button(HistoryCopy.text("Load more price records")) { Task { await model.loadPriceHistory(more: true) } }
                    .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.morePrices")
            }
        }
    }

    @ViewBuilder private var observationEditor: some View {
        Section(HistoryCopy.text("Observed item and pack")) {
            shopPicker(selection: $model.observationDraft.shopID)
            TextField(HistoryCopy.text("Item name as observed"), text: $model.observationDraft.itemName)
            TextField(HistoryCopy.text("Pack label as observed"), text: $model.observationDraft.packLabel)
            Toggle(HistoryCopy.text("Record a usable pack quantity"), isOn: $model.observationDraft.hasUsablePack)
            if model.observationDraft.hasUsablePack {
                TextField(HistoryCopy.text("Quantity numerator"), text: $model.observationDraft.packNumerator).keyboardType(.numberPad)
                TextField(HistoryCopy.text("Quantity denominator"), text: $model.observationDraft.packDenominator).keyboardType(.numberPad)
                Picker(HistoryCopy.text("Pack unit"), selection: $model.observationDraft.packUnit) {
                    ForEach(HistoryUnit.allCases, id: \.rawValue) { unit in Text(HistoryCopy.unit(unit.rawValue)).tag(unit) }
                }
                TextField(HistoryCopy.text("Original quantity wording"), text: $model.observationDraft.originalPackLiteral)
                Text(HistoryCopy.text("A mass ounce and a fluid ounce are different units. Enter the quantity shown; no density conversion is inferred."))
                    .font(.footnote)
            }
        }.disabled(model.busy)
        Section(HistoryCopy.text("Price evidence · USD")) {
            Picker(HistoryCopy.text("Price certainty"), selection: $model.observationDraft.priceKind) {
                Text(HistoryCopy.text("Exact entered price")).tag("exact")
                Text(HistoryCopy.text("Entered price range")).tag("bounded")
                Text(HistoryCopy.text("Unknown price")).tag("unknown")
            }
            if model.observationDraft.priceKind == "exact" {
                TextField(HistoryCopy.text("Price in USD"), text: $model.observationDraft.exactPrice).keyboardType(.decimalPad)
            } else if model.observationDraft.priceKind == "bounded" {
                TextField(HistoryCopy.text("Lower price in USD"), text: $model.observationDraft.lowerPrice).keyboardType(.decimalPad)
                TextField(HistoryCopy.text("Upper price in USD"), text: $model.observationDraft.upperPrice).keyboardType(.decimalPad)
            }
            if model.observationDraft.priceKind != "exact" {
                TextField(HistoryCopy.text("Why the price is uncertain"), text: $model.observationDraft.priceReason, axis: .vertical)
            }
            Text(HistoryCopy.text("Unknown is not zero. An exact zero must be entered explicitly."))
                .font(.footnote)
        }.disabled(model.busy)
        Section(HistoryCopy.text("Where and when observed")) {
            TextField(HistoryCopy.text("Store"), text: $model.observationDraft.store)
            TextField(HistoryCopy.text("Branch or location"), text: $model.observationDraft.branch)
            Picker(HistoryCopy.text("Price channel"), selection: $model.observationDraft.channel) {
                ForEach(HistoryPriceChannel.allCases, id: \.rawValue) { value in Text(HistoryCopy.channel(value.rawValue)).tag(value) }
            }
            Picker(HistoryCopy.text("Fulfillment mode"), selection: $model.observationDraft.mode) {
                ForEach(HistoryFulfillmentMode.allCases, id: \.rawValue) { value in Text(HistoryCopy.mode(value.rawValue)).tag(value) }
            }
            TextField(HistoryCopy.text("Eligibility or offer conditions, optional"), text: $model.observationDraft.eligibility, axis: .vertical)
            DatePicker(HistoryCopy.text("Evidence date and time"), selection: $model.observationDraft.observedAt)
            TextField(HistoryCopy.text("Source language or locale"), text: $model.observationDraft.sourceLocale).textInputAutocapitalization(.never)
            TextField(HistoryCopy.text("Original source text"), text: $model.observationDraft.sourceText, axis: .vertical).lineLimit(3...10)
        }.disabled(model.busy)
        Section {
            Button(HistoryCopy.text("Review this observation")) { model.reviewObservation() }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.reviewObservation").disabled(!model.canReviewObservation)
            Button(HistoryCopy.text("Cancel editing"), role: .cancel) { model.cancelReview(); editingObservation = false }
                .disabled(model.busy).frame(minHeight: 44)
        }
    }

    @ViewBuilder private var periodRecords: some View {
        Section(HistoryCopy.text("Your saved period records")) {
            Text(HistoryCopy.text("Your shared-shop selection also limits these records. Use the household overview before planning across several shops."))
                .font(.footnote)
            Button(HistoryCopy.text("Refresh saved periods")) { Task { await model.loadPeriods() } }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.loadPeriods")
            Button(HistoryCopy.text("Plan a new period")) { model.beginPeriod() }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.newPeriod").disabled(!model.canEdit)
            Text(HistoryCopy.text("Opening a saved raw plan stays Free when all its sources remain authorized. Creating plans and calculating period totals require Household membership."))
                .font(.footnote)
            ForEach(model.periods, id: \.periodId) { period in
                VStack(alignment: .leading, spacing: 6) {
                    Text(HistoryCopy.text("Saved period"))
                    Text(period.periodId).font(.caption).textSelection(.enabled)
                    LabeledContent(HistoryCopy.text("Revision"), value: period.revision.formatted())
                    Text(HistoryCopy.date(period.updatedAt)).font(.caption)
                    Button(HistoryCopy.text("Open raw saved plan")) { Task { await model.openPeriod(period.periodId) } }.accessibilityIdentifier("history.openRawPeriod")
                        .disabled(model.busy).frame(minHeight: 44)
                    Button(HistoryCopy.text("Review period totals")) { Task { await model.openPeriod(period.periodId, analyze: true) } }
                        .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.analyzePeriod")
                }
            }
            if model.periodCursor != nil {
                Button(HistoryCopy.text("Load more periods")) { Task { await model.loadPeriods(more: true) } }
                    .disabled(model.busy).frame(minHeight: 44)
            }
        }
        if let analysis = model.periodAnalysis {
            switch analysis {
            case .permittedOnly(let subtotal):
                Section(HistoryCopy.text("Permitted entered subtotal")) {
                    HistorySubtotalDetails(subtotal: subtotal)
                    Text(HistoryCopy.text("Only the currently permitted subtotal is shown. It is not a complete period balance."))
                        .font(.footnote)
                }
            case .complete(let value):
                Section(HistoryCopy.text("Period plan and entered evidence")) {
                    HistoryPeriodDetails(period: value.period)
                    HistorySubtotalDetails(subtotal: value.permitted)
                    LabeledContent(HistoryCopy.text("Future plans still reserved"), value: HistoryCopy.money(value.futureReservedMinor))
                    LabeledContent(HistoryCopy.text("Conditional minimum remaining"), value: value.remaining.minimumMinor.map(HistoryCopy.money) ?? HistoryCopy.text("Unknown"))
                    LabeledContent(HistoryCopy.text("Conditional maximum remaining"), value: HistoryCopy.money(value.remaining.maximumMinor))
                    Text(value.reconciledEnteredPeriod ? HistoryCopy.text("Entered evidence has been reconciled for this period. This is not bank verification.") : HistoryCopy.text("This period is incomplete. Remaining amounts are conditional, not a verified balance."))
                    Button(HistoryCopy.text("Edit this period plan")) { model.editSelectedPeriod() }
                        .disabled(model.busy).frame(minHeight: 44)
                }
            }
        } else if let selected = model.selectedPeriod {
            Section(HistoryCopy.text("Saved raw plan · no calculated balance")) {
                HistoryPeriodDetails(period: selected.period)
                Text(HistoryCopy.text("This raw record does not calculate a remaining balance or establish current membership."))
                    .font(.footnote)
                Button(HistoryCopy.text("Edit this period plan")) { model.editSelectedPeriod() }
                    .disabled(model.busy).frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private var periodEditor: some View {
        Section(HistoryCopy.text("Period planning envelope · USD")) {
            TextField(HistoryCopy.text("Period title"), text: periodField(\.title))
            DatePicker(HistoryCopy.text("Period starts"), selection: periodDate(\.startsAt)).environment(\.timeZone, planningTimeZone)
            DatePicker(HistoryCopy.text("Period ends"), selection: periodDate(\.endsAt)).environment(\.timeZone, planningTimeZone)
            TextField(HistoryCopy.text("Planning time zone"), text: periodField(\.timeZoneID)).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField(HistoryCopy.text("Shop budget after excluded reserve, USD"), text: periodField(\.budget)).keyboardType(.decimalPad)
            TextField(HistoryCopy.text("Reserve already excluded, optional USD"), text: periodField(\.excludedReserve)).keyboardType(.decimalPad)
            Text(HistoryCopy.text("The budget is already net of the excluded reserve. The reserve is explanatory and will not be subtracted twice."))
                .font(.footnote)
            Text(HistoryCopy.text("This is a shop-plan envelope, not a posting-date statement. Later credits for assigned shops remain part of their entered evidence."))
                .font(.footnote)
        }.disabled(model.busy)
        Section(HistoryCopy.text("Assigned shops")) {
            shopPicker(selection: $selectedShop)
            Button(HistoryCopy.text("Assign selected shop")) {
                guard !selectedShop.isEmpty, !(model.periodDraft?.shopIDs.contains(selectedShop) ?? true) else { return }
                model.periodDraft?.shopIDs.append(selectedShop)
            }.disabled(model.busy || selectedShop.isEmpty || (model.periodDraft?.shopIDs.count ?? 100) >= 100).frame(minHeight: 44)
            ForEach(model.periodDraft?.shopIDs ?? [], id: \.self) { id in
                HStack {
                    Text(id).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button(HistoryCopy.text("Remove"), role: .destructive) { model.periodDraft?.shopIDs.removeAll { $0 == id } }
                        .disabled(model.busy || (model.periodDraft?.reservations.contains { $0.state == "applied" && $0.shopID == id } ?? false))
                        .frame(minHeight: 44)
                }
            }
            Text(HistoryCopy.text("Every assigned shop is checked again before the reviewed plan can be saved."))
                .font(.footnote)
        }
        ForEach(model.periodDraft?.reservations ?? [], id: \.id) { reservation in
            Section(HistoryCopy.text("Future shop plan")) {
                if reservation.isFinal {
                    Text(reservation.originalText)
                    Text(reservation.amount)
                    Text(HistoryCopy.reservationState(reservation.state))
                    if !reservation.shopID.isEmpty { Text(reservation.shopID).font(.caption) }
                    Text(HistoryCopy.text("Applied and released evidence stays unchanged. Add a new reservation for a new plan."))
                        .font(.footnote)
                } else {
                    TextField(HistoryCopy.text("Original plan or deferral wording"), text: reservationField(reservation.id, \.originalText), axis: .vertical)
                    TextField(HistoryCopy.text("Reserved amount in USD"), text: reservationField(reservation.id, \.amount)).keyboardType(.decimalPad)
                    DatePicker(HistoryCopy.text("Planned date and time"), selection: reservationDate(reservation.id)).environment(\.timeZone, planningTimeZone)
                    Picker(HistoryCopy.text("Reservation state"), selection: reservationField(reservation.id, \.state)) {
                        Text(HistoryCopy.text("Reserved for a future shop")).tag("reserved")
                        Text(HistoryCopy.text("Released from this plan")).tag("released")
                        Text(HistoryCopy.text("Applied to an assigned shop")).tag("applied")
                    }
                    if reservation.state == "applied" {
                        Picker(HistoryCopy.text("Apply to shop"), selection: reservationField(reservation.id, \.shopID)) {
                            Text(HistoryCopy.text("Choose a shop")).tag("")
                            ForEach(model.periodDraft?.shopIDs ?? [], id: \.self) { id in Text(id).tag(id) }
                        }
                    }
                    Button(HistoryCopy.text("Remove this draft reservation"), role: .destructive) { model.periodDraft?.reservations.removeAll { $0.id == reservation.id } }
                        .frame(minHeight: 44)
                }
            }.disabled(model.busy)
        }
        Section {
            Button(HistoryCopy.text("Add a future reservation")) { model.periodDraft?.reservations.append(.init()) }
                .disabled(model.busy || (model.periodDraft?.reservations.count ?? 1000) >= 1000).frame(minHeight: 44)
            Text(HistoryCopy.text("Deferring a purchase moves expected spending. It does not establish savings. Applying a reservation transfers the plan to its assigned shop instead of counting it twice."))
                .font(.footnote)
            Toggle(HistoryCopy.text("I reviewed this ended period as complete"), isOn: Binding(get: { model.periodDraft?.reviewedComplete ?? false }, set: { model.periodDraft?.reviewedComplete = $0 }))
                .disabled(model.busy)
            if model.periodDraft?.reviewedComplete == true {
                DatePicker(HistoryCopy.text("Completion review date"), selection: periodDate(\.reviewedCompleteAt)).environment(\.timeZone, planningTimeZone).disabled(model.busy)
                Text(HistoryCopy.text("Completion review must follow the period end, with no reserved future plans. Financial reconciliation still depends on every shop's current evidence."))
                    .font(.footnote)
            }
            Button(HistoryCopy.text("Review complete period plan")) { model.reviewPeriod() }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.reviewPeriod").disabled(!model.canEdit)
            Button(HistoryCopy.text("Cancel editing"), role: .cancel) { model.cancelReview(); model.periodDraft = nil }
                .disabled(model.busy).frame(minHeight: 44)
        }
    }

    @ViewBuilder private func reviewSection(_ reviewed: HistoryReviewedWrite) -> some View {
        Section(HistoryCopy.text("Review exactly what will be saved")) {
            switch reviewed {
            case .observation(let observation): HistoryObservationDetails(observation: observation)
            case .period(let period, let revision):
                LabeledContent(HistoryCopy.text("Base revision"), value: revision.formatted())
                HistoryPeriodDetails(period: period)
            }
            Toggle(HistoryCopy.text("I reviewed these exact fields and their source"), isOn: $model.approved).disabled(model.busy)
            Button(HistoryCopy.text("Save reviewed record")) {
                Task {
                    let observationID: String?
                    if case .observation(let value) = reviewed { observationID = value.id } else { observationID = nil }
                    await model.applyReviewed()
                    if let observationID, model.selectedObservation?.id == observationID { editingObservation = false }
                }
            }
                .disabled(model.busy || !model.approved).frame(minHeight: 44).accessibilityIdentifier("history.applyReviewed")
            Button(HistoryCopy.text("Continue editing")) { model.cancelReview() }.disabled(model.busy).frame(minHeight: 44)
        }
    }
    private var pendingSection: some View {
        Section(HistoryCopy.text("Reviewed write awaiting confirmation")) {
            if let pending = model.pending {
                switch pending {
                case .observation(let intent): HistoryObservationDetails(observation: intent.observation)
                case .period(let intent):
                    LabeledContent(HistoryCopy.text("Base revision"), value: intent.baseRevision.formatted())
                    HistoryPeriodDetails(period: intent.period)
                }
            }
            Text(HistoryCopy.text("The exact reviewed record and action identity are saved for retry. A retry sends those same bytes; it does not create a second record."))
            Text(HistoryCopy.text("Current access is checked again. Do not start a replacement action while this result is uncertain."))
            Button(HistoryCopy.text("Retry and reconcile the same write")) { Task { await model.retry(); if !model.hasUnresolvedWrite { editingObservation = false } } }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.retry")
            Button(HistoryCopy.text("Review status and clear local retry"), role: .destructive) { clearingRetry = true }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("history.clearRetry")
        }
    }

    private func shopPicker(selection: Binding<String>) -> some View {
        Group {
            Picker(HistoryCopy.text("Authorized shop"), selection: selection) {
                Text(HistoryCopy.text("Choose a shop")).tag("")
                ForEach(model.ownedShops, id: \.shopId) { shop in
                    Text(HistoryCopy.shop(shop)).tag(shop.shopId)
                }
            }
            if model.ownedShopCursor != nil {
                Button(HistoryCopy.text("Load more assigned shops")) { Task { await model.loadOwnedShops(more: true) } }
                    .disabled(model.busy).frame(minHeight: 44)
            }
        }
    }
    private var planningTimeZone: TimeZone { TimeZone(identifier: model.periodDraft?.timeZoneID ?? "") ?? .current }
    private func periodField(_ key: WritableKeyPath<HistoryPeriodDraft, String>) -> Binding<String> {
        Binding(get: { model.periodDraft?[keyPath: key] ?? "" }, set: { model.periodDraft?[keyPath: key] = $0 })
    }
    private func periodDate(_ key: WritableKeyPath<HistoryPeriodDraft, Date>) -> Binding<Date> {
        Binding(get: { model.periodDraft?[keyPath: key] ?? Date() }, set: { model.periodDraft?[keyPath: key] = $0 })
    }
    private func reservationField(_ id: String, _ key: WritableKeyPath<HistoryReservationDraft, String>) -> Binding<String> {
        Binding(get: { model.periodDraft?.reservations.first { $0.id == id }?[keyPath: key] ?? "" }, set: { value in
            guard var draft = model.periodDraft, let index = draft.reservations.firstIndex(where: { $0.id == id }), !draft.reservations[index].isFinal else { return }
            draft.reservations[index][keyPath: key] = value; model.periodDraft = draft
        })
    }
    private func reservationDate(_ id: String) -> Binding<Date> {
        Binding(get: { model.periodDraft?.reservations.first { $0.id == id }?.plannedAt ?? Date() }, set: { value in
            guard var draft = model.periodDraft, let index = draft.reservations.firstIndex(where: { $0.id == id }), !draft.reservations[index].isFinal else { return }
            draft.reservations[index].plannedAt = value; model.periodDraft = draft
        })
    }
}

private struct HistoryObservationDetails: View {
    let observation: HistoryPriceObservation
    var body: some View {
        Group {
            Text(observation.itemName).font(.headline)
            LabeledContent(HistoryCopy.text("Pack label"), value: observation.packLabel)
            if let pack = observation.usablePack {
                LabeledContent(HistoryCopy.text("Original quantity wording"), value: pack.originalLiteral)
                Text("\(pack.amount.numerator)/\(pack.amount.denominator) " + HistoryCopy.unit(pack.unit.rawValue))
            } else { Text(HistoryCopy.text("Usable pack quantity not recorded")) }
            switch observation.price {
            case .exact(let minor): LabeledContent(HistoryCopy.text("Entered price"), value: HistoryCopy.money(minor))
            case .bounded(let lower, let upper, let reason):
                LabeledContent(HistoryCopy.text("Entered price range"), value: HistoryCopy.money(lower) + " – " + HistoryCopy.money(upper))
                Text(reason)
            case .unknown(let reason): Text(HistoryCopy.text("Unknown price")); Text(reason)
            }
            LabeledContent(HistoryCopy.text("Store"), value: observation.store)
            LabeledContent(HistoryCopy.text("Branch or location"), value: observation.branch)
            Text(HistoryCopy.channel(observation.channel.rawValue))
            Text(HistoryCopy.mode(observation.mode.rawValue))
            if !observation.eligibility.isEmpty { LabeledContent(HistoryCopy.text("Eligibility"), value: observation.eligibility) }
            LabeledContent(HistoryCopy.text("Evidence date and time"), value: HistoryCopy.date(observation.observedAt))
            LabeledContent(HistoryCopy.text("Source language or locale"), value: observation.sourceLocale)
            Text(observation.sourceText).textSelection(.enabled)
            LabeledContent(HistoryCopy.text("Observation reference"), value: observation.id).font(.caption).textSelection(.enabled)
        }
    }
}

private struct HistoryPeriodDetails: View {
    let period: HistoryBudgetPeriod
    var body: some View {
        Group {
            Text(period.title).font(.headline)
            LabeledContent(HistoryCopy.text("Period starts"), value: HistoryCopy.date(period.startsAt, timeZoneID: period.timeZoneId))
            LabeledContent(HistoryCopy.text("Period ends"), value: HistoryCopy.date(period.endsAt, timeZoneID: period.timeZoneId))
            LabeledContent(HistoryCopy.text("Planning time zone"), value: period.timeZoneId)
            LabeledContent(HistoryCopy.text("Shop budget after excluded reserve"), value: HistoryCopy.money(period.shopBudgetMinor))
            if let reserve = period.alreadyExcludedReserveMinor {
                LabeledContent(HistoryCopy.text("Reserve already excluded"), value: HistoryCopy.money(reserve))
            }
            ForEach(period.shopIds, id: \.self) { id in LabeledContent(HistoryCopy.text("Assigned shop reference"), value: id).font(.caption) }
            ForEach(period.reservations, id: \.id) { reservation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(reservation.originalText)
                    Text(HistoryCopy.money(reservation.amountMinor))
                    Text(HistoryCopy.date(reservation.plannedAt, timeZoneID: period.timeZoneId))
                    switch reservation.state {
                    case .reserved: Text(HistoryCopy.text("Reserved for a future shop"))
                    case .released: Text(HistoryCopy.text("Released from this plan"))
                    case .applied(let shopID): Text(HistoryCopy.text("Applied to an assigned shop")); Text(shopID).font(.caption)
                    }
                }
            }
            if let reviewed = period.reviewedCompleteAt {
                LabeledContent(HistoryCopy.text("Completion review date"), value: HistoryCopy.date(reviewed, timeZoneID: period.timeZoneId))
            }
            LabeledContent(HistoryCopy.text("Period reference"), value: period.id).font(.caption).textSelection(.enabled)
        }
    }
}

private struct HistorySubtotalDetails: View {
    let subtotal: HistoryPermittedSubtotal
    var body: some View {
        Group {
            LabeledContent(HistoryCopy.text("Entered posted net spending"), value: HistoryCopy.money(subtotal.postedNetMinor))
            LabeledContent(HistoryCopy.text("Expected credits, not yet deducted"), value: HistoryCopy.money(subtotal.pendingCreditsMinor))
            LabeledContent(HistoryCopy.text("Credits already included, not deducted again"), value: HistoryCopy.money(subtotal.includedCreditsMinor))
            LabeledContent(HistoryCopy.text("Payment holds, not spending"), value: HistoryCopy.money(subtotal.paymentHoldsMinor))
            LabeledContent(HistoryCopy.text("Expected unpaid amount"), value: HistoryCopy.range(subtotal.expectedUnpaid))
            LabeledContent(HistoryCopy.text("Projected commitment including posted spending"), value: HistoryCopy.range(subtotal.projectedCommitment))
            Text(HistoryCopy.text("Pending credits do not reduce posted spending. Holds are separate. A missing upper bound keeps the minimum remaining amount unknown."))
                .font(.footnote)
            ForEach(subtotal.shops, id: \.shopId) { shop in
                DisclosureGroup {
                    LabeledContent(HistoryCopy.text("Entered posted net spending"), value: HistoryCopy.money(shop.postedNetMinor))
                    LabeledContent(HistoryCopy.text("Expected unpaid amount"), value: HistoryCopy.range(shop.expectedUnpaid))
                    Text(shop.reconciledEntered ? HistoryCopy.text("Current entered evidence reconciled") : HistoryCopy.text("Shop evidence remains incomplete"))
                } label: { Text(shop.shopId).font(.caption) }
            }
        }
    }
}
