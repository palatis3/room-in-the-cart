import SwiftUI

struct RecordsPantryErasureSection: View {
    @ObservedObject var model: RecordsPantryErasureModel
    var didDismiss: @MainActor () async -> Void = {}
    @State private var presenting = false

    var body: some View {
        Section {
            Button(recordsText("Delete pantry data")) { presenting = true }
        }
        .sheet(isPresented: $presenting, onDismiss: { Task { await didDismiss() } }) {
            NavigationStack {
                PantryErasureReviewView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(recordsText("Done")) { presenting = false }.disabled(model.busy)
                        }
                    }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }
}

private struct PantryErasureReviewView: View {
    @ObservedObject var model: RecordsPantryErasureModel
    @AccessibilityFocusState private var resultFocused: Bool

    var body: some View {
        Form {
            if let review = model.review {
                PantryErasureImpactView(model: model, review: review).id(review.id)
            } else if model.listed {
                Section(recordsText("Choose what to delete")) {
                    ForEach(model.choices) { choice in
                        Button {
                            Task { await model.prepare(choice) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(choiceTitle(choice))
                                if let detail = choiceDetail(choice) { Text(detail).font(.caption) }
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                    if model.choices.isEmpty { Text(recordsText("There are no pantry records to delete.")) }
                }
            }
            if let notice = model.notice {
                Section {
                    Text(message(notice)).accessibilityFocused($resultFocused)
                    if notice == .cleanupPending {
                        Button(recordsText("Retry confirmed cleanup")) { Task { await model.recoverCleanup() } }
                    }
                }
            }
            if model.busy { ProgressView(recordsText("Working…")) }
            if model.review == nil, model.notice != .cleanupPending, !model.busy {
                Button(recordsText("Refresh pantry deletion choices")) { Task { await model.load() } }
            }
        }
        .disabled(model.busy)
        .privacySensitive()
        .navigationTitle(recordsText("Delete pantry data"))
        .task { await model.load() }
        .onDisappear { model.invalidate() }
        .onChange(of: model.notice) { _, value in resultFocused = value != nil }
    }

    private func choiceTitle(_ choice: RecordsPantryErasureModel.Choice) -> String {
        if case .wholeOrigin = choice.selection { return recordsText("Entire local pantry") }
        if case .pickup = choice.selection, choice.title == "Pickup" { return recordsText("Pickup") }
        return choice.title
    }

    private func choiceDetail(_ choice: RecordsPantryErasureModel.Choice) -> String? {
        switch choice.selection {
        case .lot(let id, _): return recordsText("Food batch") + " · " + id.uuidString.suffix(8)
        case .pickup(let id, _, _): return recordsText("Pickup") + " · " + id.uuidString.suffix(8)
        case .price(let id, _): return pantryText("Private price history") + " · " + id.uuidString.suffix(8)
        case .wholeOrigin: return nil
        }
    }

    private func message(_ notice: RecordsPantryErasureModel.Notice) -> String {
        switch notice {
        case .stale: return recordsText("These records changed. Refresh and review the deletion again.")
        case .unavailable: return recordsText("Unlock the private workspace to review pantry deletion.")
        case .failed: return recordsText("Couldn’t verify the deletion status. Refresh to check the pantry records.")
        case .cleanupPending: return recordsText("A confirmed pantry deletion has unfinished cleanup on this iPhone.")
        case .deleted: return recordsText("The reviewed pantry data was deleted from this iPhone.")
        case .noPendingCleanup: return recordsText("There is no confirmed cleanup left to finish.")
        }
    }
}

private struct PantryErasureImpactView: View {
    @ObservedObject var model: RecordsPantryErasureModel
    let review: RecordsPantryErasureModel.Review
    @State private var acknowledged = false

    var body: some View {
        Section(recordsText("Review pantry deletion")) {
            switch review.selection {
            case .lot:
                if review.foodNames.count > 1 {
                    Text(pantryText("This batch was split. Deleting its transfer history also deletes the linked portions listed below."))
                } else { Text(recordsText("You selected one food batch.")) }
            case .pickup: Text(recordsText("You selected one pickup and its pantry records."))
            case .price: Text(pantryText("You selected one price and its corrections and credits."))
            case .wholeOrigin: Text(recordsText("You selected the entire local pantry and its history."))
            }
        }
        rows(recordsText("Food batches to delete"), review.foodNames)
        if review.sharedReceiptCount > 0 {
            LabeledContent(pantryText("Pending shared receipt files to delete"), value: review.sharedReceiptCount.formatted())
        }
        if review.priceRevisionCount > 0 {
            LabeledContent(pantryText("Price revisions to delete"), value: review.priceRevisionCount.formatted())
        }
        if review.aliasCount > 0 {
            LabeledContent(pantryText("Saved receipt spellings to delete"), value: review.aliasCount.formatted())
        }
        if review.receiptRevisionCount > 0 {
            LabeledContent(pantryText("Receipt and paid-price revisions to delete"), value: review.receiptRevisionCount.formatted())
        }
        pickupRows(recordsText("Pickups to delete"), review.pickups)
        if case .wholeOrigin = review.selection {
            rows(recordsText("Meal reservations to delete"), review.affectedReservationNames)
        } else {
            rows(recordsText("Reservations whose history or backing will change"), review.affectedReservationNames)
        }
        pickupRows(recordsText("Other pickups that depend on these records"), review.collateralPickups)
        rows(recordsText("Receipt food that will be kept"), review.retainedReceiptFoodNames)
        rows(recordsText("Recovered pantry copies to delete"), review.copyIDs.map(\.uuidString))
        if review.pendingFileCount > 0 {
            Section {
                LabeledContent(recordsText("Pending change files to delete"), value: review.pendingFileCount.formatted())
            }
        }
        if !review.canCommit || !review.blockers.isEmpty || !review.collateralPickups.isEmpty {
            Section(recordsText("Deletion is blocked")) {
                if review.blockers.contains(.collateralPickups) || !review.collateralPickups.isEmpty {
                    Text(recordsText("Other pickups contain related records. Your selection does not include those pickups."))
                }
                if review.blockers.contains(.retainedReceiptEvidence) {
                    Text(pantryText("A retained food batch has receipt evidence from this pickup. Review that batch before deleting the pickup."))
                }
                if review.blockers.contains(.ledgerHistory) {
                    Text(recordsText("Related shopping ledger history must be resolved before these records can be deleted."))
                }
                if review.blockers.contains(.unknownContent) {
                    Text(recordsText("Some stored content could not be checked for related pantry data."))
                }
                if review.blockers.contains(.recoveredRecords) {
                    Text(recordsText("Related recovered records must be reviewed separately."))
                }
            }
        } else {
            Section {
                Toggle(recordsText("I reviewed the records and permanent changes listed above."), isOn: $acknowledged)
                Button(recordsText("Permanently delete reviewed pantry data"), role: .destructive) {
                    Task { await model.commit(reviewID: review.id) }
                }
                .disabled(!acknowledged || model.busy)
            } footer: {
                Text(recordsText("Files you previously exported stay wherever you saved them."))
            }
        }
        Button(recordsText("Cancel deletion review"), role: .cancel) { model.cancelReview() }
    }

    @ViewBuilder private func pickupRows(_ title: String, _ pickups: [RecordsPantryErasureModel.Pickup]) -> some View {
        if !pickups.isEmpty {
            Section(title) {
                ForEach(pickups) { pickup in
                    let name = pickup.title == "Pickup" ? recordsText("Pickup") : pickup.title
                    Text(verbatim: name + " · " + pickup.id.uuidString.suffix(8))
                }
            }
        }
    }

    @ViewBuilder private func rows(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            Section(title) {
                ForEach(values.indices, id: \.self) { index in Text(verbatim: values[index]) }
            }
        }
    }
}
