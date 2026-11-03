import SwiftUI
import HouseholdClient

struct PlacementEntryView: View {
    @ObservedObject var model: PlacementFeatureModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var retireReview = false
    @State private var discardCapture = false
    var body: some View {
        Form {
            Section {
                Text(PlacementCopy.text("Report what happened outside this app"))
                Text(PlacementCopy.text("Saving a snapshot, sharing a list, or opening a retailer does not place an order. Only report placement after you have checked what happened with the retailer."))
                    .font(.footnote)
                Text(PlacementCopy.text("This app records a person's report. It does not verify an order, charge, payment or cancellation with the retailer."))
                    .font(.footnote)
            }
            if model.authorized {
                if let review = model.reviewed { reviewSection(review) }
                else {
                    localRecords
                    if let selected = model.selected { selectedRecord(selected) }
                    if model.canManage {
                        if let pending = model.pendingReview { reconciliationRetry(pending) }
                        currentShopSection
                        reconciliationSection
                    }
                }
                if let notice = model.notice {
                    Section { Text(notice).accessibilityIdentifier("placement.notice") }
                }
                if model.busy { ProgressView(PlacementCopy.text("Checking placement records…")) }
            } else {
                Section {
                    Text(PlacementCopy.text("Open your enrolled adult household account to view your saved placement records."))
                    Button(PlacementCopy.text("Open my saved placement records")) { Task { await model.load() } }
                        .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle(PlacementCopy.text("Shared placement reports"))
        .accessibilityIdentifier("placement.home")
        .task { await model.load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                model.enforceRuntime()
            }
        }
        .onDisappear { model.invalidate(); retireReview = false; discardCapture = false }
        .confirmationDialog(PlacementCopy.text("Retire this local reconciliation attempt?"), isPresented: $retireReview, titleVisibility: .visible) {
            Button(PlacementCopy.text("Check status and retire local attempt"), role: .destructive) {
                Task { await model.retireReconciliationAfterStatusReview() }
            }
        } message: {
            Text(PlacementCopy.text("The current report status will be checked first. Retiring this local attempt does not undo a received decision or prove which action resolved the report."))
        }
        .confirmationDialog(PlacementCopy.text("Discard this unused local snapshot?"), isPresented: $discardCapture, titleVisibility: .visible) {
            Button(PlacementCopy.text("Discard unused local snapshot"), role: .destructive) {
                Task { await model.discardUnreportedCapture() }
            }
        } message: {
            Text(PlacementCopy.text("Only this unreported local snapshot will be removed. A sealed placement report cannot be discarded or given a new action identity. This does not cancel a retailer order."))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.invalidate() }
            if phase == .active { Task { await model.load() } }
        }
    }
    @ViewBuilder private var localRecords: some View {
        Section(PlacementCopy.text("My captured snapshots")) {
            Text(PlacementCopy.text("Capture the reviewed shop before leaving for checkout. Your saved snapshot can be reviewed without loading the current shopper's private basket."))
                .font(.footnote)
            Button(PlacementCopy.text("Reload my saved snapshots")) { Task { await model.load() } }
                .disabled(model.busy).frame(minHeight: 44)
            ForEach(model.saved, id: \.id) { record in
                Button { model.selectSaved(id: record.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(PlacementCopy.text("Captured shop snapshot"))
                        Text(PlacementCopy.date(record.capture.capturedAt))
                        Text(record.capture.snapshot.shopId).font(.caption)
                        if let receipt = record.receipt { Text(PlacementCopy.outcome(receipt.disposition)) }
                        else if record.report != nil { Text(PlacementCopy.text("Report awaiting confirmation")) }
                        else { Text(PlacementCopy.text("Saved locally · not reported placed")) }
                    }
                }.disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.openCapture")
            }
        }
    }
    @ViewBuilder private func selectedRecord(_ record: PlacementLocalRecord) -> some View {
        Section(PlacementCopy.text("Original captured shop")) {
            capturedIdentity(record.capture)
            if let report = record.report {
                LabeledContent(PlacementCopy.text("Reported occurrence time"), value: PlacementCopy.date(report.occurredAt))
            }
            PlacementShopFacts(quote: record.capture.snapshot.quote, lines: record.capture.snapshot.lines)
                PlacementMealFacts(meals: record.capture.snapshot.meals ?? [])
        }
        if let receipt = record.receipt {
            Section(PlacementCopy.text("Your report receipt")) {
                Text(PlacementCopy.outcome(receipt.disposition)).font(.headline)
                LabeledContent(PlacementCopy.text("Report reference"), value: receipt.reportId).font(.caption).textSelection(.enabled)
                Text(PlacementCopy.text("This receipt confirms how the app handled your report. It does not confirm retailer placement or a charge."))
                    .font(.footnote)
            }
        } else if let report = record.report {
            Section(record.status == nil ? PlacementCopy.text("Original report awaiting confirmation") : PlacementCopy.text("Original submitted report")) {
                LabeledContent(PlacementCopy.text("Reported occurrence time"), value: PlacementCopy.date(report.occurredAt))
                Text(PlacementCopy.text("Retry preserves the same snapshot, assignment version, occurrence time and action identity. No current shop revision is substituted."))
                    .font(.footnote)
                if model.reportWindowExpired {
                    Text(PlacementCopy.text("The original report window has expired. Check its recorded status; no new report identity will be created."))
                }
                if record.status == nil {
                    Button(PlacementCopy.text("Retry this exact placement report")) { Task { await model.retryReport() } }
                        .disabled(!model.canRetryReport).frame(minHeight: 44).accessibilityIdentifier("placement.retryReport")
                }
            }
        } else {
            Section(PlacementCopy.text("After checking with the retailer")) {
                DatePicker(PlacementCopy.text("When I placed this order"), selection: $model.occurredAt)
                    .disabled(model.busy)
                Text(PlacementCopy.text("Use the actual occurrence time. If reporting later or after a shopper transfer, the original captured snapshot and assignment remain attached."))
                    .font(.footnote)
                Button(PlacementCopy.text("Review my placement report")) { model.reviewReport() }
                    .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.reviewReport").disabled(!model.canReport)
                Button(PlacementCopy.text("Discard unused local snapshot"), role: .destructive) { discardCapture = true }
                    .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.discardCapture")
            }
        }
        if record.report != nil {
            Section {
                Button(PlacementCopy.text("Check my original report status")) { Task { await model.refreshReporterStatus() } }
                    .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.reportStatus")
                Text(PlacementCopy.text("Status checks use the original report identity. An expired retry is not replaced with a new action."))
                    .font(.footnote)
            }
        }
        if let status = record.status {
            Section(PlacementCopy.text("Current status of my report")) {
                Text(PlacementCopy.outcome(status.state))
                LabeledContent(PlacementCopy.text("Reported occurrence time"), value: PlacementCopy.date(status.occurredAt))
                LabeledContent(PlacementCopy.text("Received by this app"), value: PlacementCopy.date(status.receivedAt))
                Text(PlacementCopy.text("This status contains your report's disposition, not another shopper's current budget or basket."))
                    .font(.footnote)
            }
        }
    }
    @ViewBuilder private var currentShopSection: some View {
        Section(PlacementCopy.text("Current shopper's checkout snapshot")) {
            Button(PlacementCopy.text("Refresh current shopper facts")) { Task { await model.refreshCurrent() } }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.refreshCurrent")
            Text(PlacementCopy.text("This separate online check requires current shopper access. A saved report never grants that access."))
                .font(.footnote)
            if let current = model.currentShop {
                LabeledContent(PlacementCopy.text("Shop reference"), value: current.shopId).font(.caption)
                LabeledContent(PlacementCopy.text("Current shop revision"), value: current.shopRevision.formatted())
                LabeledContent(PlacementCopy.text("Current shopper assignment version"), value: current.authorityEpoch.formatted())
                Text(PlacementCopy.phase(current.phase))
                if let frozen = current.frozenRevision {
                    LabeledContent(PlacementCopy.text("Current frozen revision"), value: frozen.formatted())
                }
                PlacementShopFacts(quote: current.quote, lines: current.lines)
                PlacementMealFacts(meals: current.meals ?? [])
                Button(PlacementCopy.text("Review this snapshot for offline reporting")) { model.reviewCapture() }
                    .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.reviewCapture").disabled(!model.canCapture)
            }
        }
    }
    @ViewBuilder private var reconciliationSection: some View {
        Section(PlacementCopy.text("Reports for the current shopper")) {
            Button(PlacementCopy.text("Refresh pending placement reports")) { Task { await model.loadReports() } }
                .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.loadReports")
            Text(PlacementCopy.text("Review the complete reported snapshot against the current frozen shop before applying it. A different snapshot cannot silently place the current basket."))
                .font(.footnote)
            if let page = model.reportPage {
                LabeledContent(PlacementCopy.text("Current shop revision"), value: page.shopRevision.formatted())
                LabeledContent(PlacementCopy.text("Current shopper assignment version"), value: page.authorityEpoch.formatted())
                Text(PlacementCopy.phase(page.phase))
                LabeledContent(PlacementCopy.text("Current frozen revision"), value: page.frozenRevision?.formatted() ?? PlacementCopy.text("No frozen revision"))
                ForEach(model.reports, id: \.reportId) { report in
                    DisclosureGroup {
                        PlacementReportedFacts(report: report)
                        if page.phase != "frozen" || page.frozenRevision != report.reportedRevision {
                            Text(PlacementCopy.text("This report does not match the current frozen revision. It cannot be applied to the current basket."))
                                .font(.footnote)
                        }
                        Button(PlacementCopy.text("Review applying this report")) { model.reviewReconciliation(report, choice: .apply) }
                            .disabled(model.busy || model.pendingReview != nil || page.phase != "frozen" || page.frozenRevision != report.reportedRevision)
                            .frame(minHeight: 44).accessibilityIdentifier("placement.reviewApply")
                        Button(PlacementCopy.text("Review rejecting this report")) { model.reviewReconciliation(report, choice: .reject) }
                            .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.reviewReject").disabled(model.pendingReview != nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PlacementCopy.text("Pending placement report"))
                            Text(PlacementCopy.date(report.occurredAt))
                            Text(report.reportId).font(.caption)
                        }
                    }
                }
                if model.reportCursor != nil {
                    Button(PlacementCopy.text("Load more placement reports")) { Task { await model.loadReports(more: true) } }
                        .disabled(model.busy).frame(minHeight: 44)
                }
            }
        }
    }
    @ViewBuilder private func reconciliationRetry(_ pending: PlacementLocalReview) -> some View {
        Section(PlacementCopy.text("Original reconciliation action")) {
            Text(pending.intent.choice == .apply ? PlacementCopy.text("Apply the reviewed report to this app shop") : PlacementCopy.text("Reject applying this report to this app shop"))
            LabeledContent(PlacementCopy.text("Shop revision originally reviewed"), value: pending.intent.base.shopRevision.formatted())
            LabeledContent(PlacementCopy.text("Shopper assignment originally reviewed"), value: pending.intent.base.authorityEpoch.formatted())
            LabeledContent(PlacementCopy.text("Frozen revision originally reviewed"), value: pending.currentSnapshot.frozenRevision?.formatted() ?? PlacementCopy.text("No frozen revision"))
            LabeledContent(PlacementCopy.text("Original retry window ends"), value: PlacementCopy.date(pending.intent.replayWindow.expiresAt))
            PlacementReportedFacts(report: pending.intent.report)
            if let receipt = pending.receipt {
                Text(PlacementCopy.outcome(receipt.disposition))
                Text(PlacementCopy.text("The app confirmed this reviewed decision. This is not retailer verification."))
            }
            if let status = pending.status {
                LabeledContent(PlacementCopy.text("Current report status"), value: PlacementCopy.outcome(status.report.state))
                Text(PlacementCopy.text("A current status and the original action receipt are different evidence. A handled report is not sent again."))
                    .font(.footnote)
                if status.report.resolutionClientKey == pending.intent.id {
                    Text(PlacementCopy.text("The recorded resolution identifies this original reconciliation action."))
                } else if status.report.state != "pending_reconciliation" {
                    Text(PlacementCopy.text("A resolution is recorded, but this status does not identify your original action as its cause."))
                }
            }
            if model.reviewWindowExpired {
                Text(PlacementCopy.text("The original reconciliation window has expired. Check status before explicitly reviewing any new action."))
            }
            if pending.retired { Text(PlacementCopy.text("This local reconciliation attempt was retired after status review.")) }
            else {
                Button(PlacementCopy.text("Retry this exact reconciliation")) { Task { await model.retryReconciliation() } }
                    .disabled(!model.canRetryReconciliation)
                    .frame(minHeight: 44).accessibilityIdentifier("placement.retryReconciliation")
                Button(PlacementCopy.text("Check reconciliation status")) { Task { await model.refreshReconciliationStatus() } }
                    .disabled(model.busy).frame(minHeight: 44).accessibilityIdentifier("placement.reconciliationStatus")
                Button(PlacementCopy.text("Review retiring this local attempt"), role: .destructive) { retireReview = true }
                    .disabled(model.busy).frame(minHeight: 44)
            }
        }
    }
    @ViewBuilder private func reviewSection(_ review: PlacementReview) -> some View {
        Section(PlacementCopy.text("Review this exact action")) {
            switch review {
            case .capture(let shop):
                Text(PlacementCopy.text("Save a local checkout snapshot"))
                LabeledContent(PlacementCopy.text("Original shop revision"), value: shop.shopRevision.formatted())
                LabeledContent(PlacementCopy.text("Original shopper assignment version"), value: shop.authorityEpoch.formatted())
                PlacementShopFacts(quote: shop.quote, lines: shop.lines)
                PlacementMealFacts(meals: shop.meals ?? [])
                Text(PlacementCopy.text("This saves a dated snapshot on this iPhone. It does not report an order as placed."))
            case .report(let intent):
                Text(PlacementCopy.text("Report external placement"))
                LabeledContent(PlacementCopy.text("Reported occurrence time"), value: PlacementCopy.date(intent.occurredAt))
                capturedIdentity(intent.prepared)
                PlacementShopFacts(quote: intent.prepared.snapshot.quote, lines: intent.prepared.snapshot.lines)
                PlacementMealFacts(meals: intent.prepared.snapshot.meals ?? [])
                Text(PlacementCopy.text("If the shop or shopper changed, the report remains separately attributed for the current shopper to reconcile."))
            case .reconcile(let page, let report, let choice):
                Text(choice == .apply ? PlacementCopy.text("Apply the reviewed report to this app shop") : PlacementCopy.text("Reject applying this report to this app shop"))
                LabeledContent(PlacementCopy.text("Current shop revision"), value: page.shopRevision.formatted())
                LabeledContent(PlacementCopy.text("Current shopper assignment version"), value: page.authorityEpoch.formatted())
                LabeledContent(PlacementCopy.text("Current frozen revision"), value: page.frozenRevision?.formatted() ?? PlacementCopy.text("No frozen revision"))
                PlacementReportedFacts(report: report)
                Text(PlacementCopy.text("This decision affects the app's placement record. It does not place, cancel or amend a retailer order."))
            }
            Toggle(PlacementCopy.text("I reviewed this snapshot, time and action"), isOn: $model.approved).disabled(model.busy)
            Button(PlacementCopy.text("Confirm reviewed action")) { Task { await model.applyReviewed() } }
                .disabled(!model.canApply).frame(minHeight: 44).accessibilityIdentifier("placement.applyReviewed")
            Button(PlacementCopy.text("Return without applying")) { model.cancelReview() }
                .disabled(model.busy).frame(minHeight: 44)
        }
    }
    @ViewBuilder private func capturedIdentity(_ capture: PlacementPreparedSnapshot) -> some View {
        LabeledContent(PlacementCopy.text("Shop reference"), value: capture.snapshot.shopId).font(.caption)
        LabeledContent(PlacementCopy.text("Captured on this iPhone"), value: PlacementCopy.date(capture.capturedAt))
        LabeledContent(PlacementCopy.text("Original shop revision"), value: capture.snapshot.shopRevision.formatted())
        LabeledContent(PlacementCopy.text("Original shopper assignment version"), value: capture.snapshot.authorityEpoch.formatted())
        LabeledContent(PlacementCopy.text("Original retry window ends"), value: PlacementCopy.date(capture.replayWindow.expiresAt))
        Text(PlacementCopy.text("If the retry window expires, a missing receipt is not proof that placement failed. Check the original report status before deciding what happened."))
            .font(.footnote)
    }
}

struct PlacementReportedFacts: View {
    let report: PlacementPendingReport
    var body: some View {
        Group {
            LabeledContent(PlacementCopy.text("Report reference"), value: report.reportId).font(.caption).textSelection(.enabled)
            LabeledContent(PlacementCopy.text("Reported occurrence time"), value: PlacementCopy.date(report.occurredAt))
            LabeledContent(PlacementCopy.text("Received by this app"), value: PlacementCopy.date(report.receivedAt))
            LabeledContent(PlacementCopy.text("Original shop revision"), value: report.reportedRevision.formatted())
            LabeledContent(PlacementCopy.text("Original shopper assignment version"), value: report.reportedAuthorityEpoch.formatted())
            LabeledContent(PlacementCopy.text("Original snapshot saved"), value: PlacementCopy.date(report.snapshotCreatedAt))
            PlacementShopFacts(quote: report.snapshot.quote, lines: report.snapshot.lines)
            PlacementBudgetFacts(budget: report.snapshot.budget)
            ForEach(report.snapshot.mealRefs ?? [], id: \.occurrenceId) { meal in
                LabeledContent(PlacementCopy.text("Original meal reference"), value: meal.occurrenceId).font(.caption)
                LabeledContent(PlacementCopy.text("Original meal revision"), value: meal.revision.formatted())
            }
            Text(PlacementCopy.text("The original reported basket and time are preserved separately from the current shop."))
                .font(.footnote)
        }
    }
}
