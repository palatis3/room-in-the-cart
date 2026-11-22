import CoreDomain
import SwiftUI

struct PantryReceiptRescanView: View {
    @ObservedObject var model: PantryModel
    let prompt: ReceiptRescanPrompt
    let choose: (ReceiptRescanDecision) -> Void
    let edit: () -> Void
    @State private var selected: UUID?
    @State private var links: [Int: UUID] = [:]
    private(set) var dates = ReceiptDateDisplay()

    var body: some View {
        Section(pantryText("Compare a possible earlier receipt")) {
            Text(pantryText("These saved receipts share the store, purchase day and printed food wording. Check which purchase this is."))
            if prompt.truncated { Text(pantryText("Only the first eight possible receipts are shown. Check Receipt history if yours is missing.")) }
            ForEach(prompt.candidates) { candidate in
                Button(title(for: candidate)) { select(candidate) }
                    .accessibilityIdentifier("receipt.rescan.candidate.\(candidate.id)")
                if selected == candidate.id { comparison(for: candidate) }
            }
            if prompt.linkedReceipt == nil {
                Button(pantryText("This is a separate purchase")) {
                    choose(.init(basis: prompt.basis, receipt: nil, existingByOrdinal: [:]))
                }.accessibilityIdentifier("receipt.rescan.separate")
            }
            Button(pantryText("Edit selected lines"), action: edit)
        }
    }

    private func title(for candidate: ReceiptRescanPrompt.Candidate) -> String {
        let first = candidate.original.first
        let date = first.map { dates.purchaseDay($0.purchaseDate, style: .abbreviated) }
        let reference = first?.transactionReference ?? String(candidate.id.uuidString.suffix(8))
        return [first?.merchant, date, reference].compactMap { $0 }.joined(separator: " · ")
    }

    private func select(_ candidate: ReceiptRescanPrompt.Candidate) {
        selected = candidate.id
        var initial: [Int: UUID] = [:]
        for row in prompt.rows {
            guard prompt.fixed[row.ordinal] == nil,
                  let matches = candidate.matches[row.ordinal], matches.count == 1,
                  let match = matches.first, !prompt.fixed.values.contains(match) else { continue }
            let matchingRows = candidate.matches.values.filter { $0.contains(match) }
            if matchingRows.count == 1 { initial[row.ordinal] = match }
        }
        links = initial
    }

    @ViewBuilder private func comparison(for candidate: ReceiptRescanPrompt.Candidate) -> some View {
        Text(pantryText("Previously confirmed lines")).font(.headline)
        ForEach(candidate.original) { fact in originalLine(fact) }
        NavigationLink(pantryText("Open original receipt and price corrections")) {
            PantryReceiptHistory(model: model, receiptID: candidate.id, permittedLines: Set(candidate.original.map(\.lineID)))
        }
        Text(pantryText("Selected lines on this document")).font(.headline)
        ForEach(prompt.rows) { row in selectedLine(row, candidate: candidate) }
        Button(pantryText("Review against this original")) {
            choose(.init(basis: prompt.basis, receipt: candidate.id, existingByOrdinal: links))
        }.accessibilityIdentifier("receipt.rescan.original")
    }

    private func originalLine(_ fact: ReceiptAcquisition) -> some View {
        VStack(alignment: .leading) {
            Text(verbatim: fact.originalLine).font(.headline)
            Text(verbatim: fact.name)
            if case .added(let location) = fact.stock { Text(pantryLocationName(location)) }
            Text(pantryFormat("Received %@", pantryQuantity(fact.received)))
            Text(pantryFormat("Usable %@", pantryQuantity(fact.usable)))
            if let paid = fact.paidLineTotal { Text(pantryFormat("Paid line total %@", receiptMoney(paid))) }
            else { Text(pantryText("Paid price unknown")) }
        }
    }

    private func selectedLine(_ row: ReceiptImportDraft.Line, candidate: ReceiptRescanPrompt.Candidate) -> some View {
        VStack(alignment: .leading) {
            Text(verbatim: row.original)
            Text(verbatim: row.name)
            if row.treatment == .add { Text(pantryLocationName(row.location)) }
            Text(pantryFormat("Received %@", pantryPrintedQuantity(row.received, unit: row.unit)))
            Text(pantryFormat("Usable %@", pantryPrintedQuantity(row.usable, unit: row.unit)))
                .accessibilityIdentifier("receipt.rescan.usable.\(row.ordinal)")
            if !row.paid.isEmpty { Text(pantryFormat("Paid line total %@", row.paid)) }
            lineMatch(for: row.ordinal, candidate: candidate)
        }
    }

    @ViewBuilder private func lineMatch(for ordinal: Int, candidate: ReceiptRescanPrompt.Candidate) -> some View {
        let matches = candidate.matches[ordinal] ?? []
        if prompt.fixed[ordinal] != nil {
            Text(pantryText("Previously saved on this receipt."))
        } else if matches.isEmpty {
            Text(pantryText("New selected line on this receipt"))
        } else {
            let selection = Binding<UUID?>(get: { links[ordinal] }, set: { links[ordinal] = $0 })
            Picker(pantryText("Match this printed line"), selection: selection) {
                Text(pantryText("Additional line")).tag(UUID?.none)
                ForEach(candidate.original.filter { matches.contains($0.id) }) { old in
                    let label = old.name + " · " + pantryQuantity(old.received) + " · " + String(old.lineID.uuidString.suffix(8))
                    Text(label).tag(Optional(old.id))
                }
            }
        }
    }
}
