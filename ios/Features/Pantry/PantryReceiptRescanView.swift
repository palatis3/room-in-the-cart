import CoreDomain
import SwiftUI

struct PantryReceiptRescanView: View {
    @ObservedObject var model: PantryModel
    let prompt: ReceiptRescanPrompt
    let choose: (ReceiptRescanDecision) -> Void
    let edit: () -> Void
    @State private var selected: UUID?
    @State private var links: [Int: UUID] = [:]

    var body: some View {
        Section(pantryText("Compare a possible earlier receipt")) {
            Text(pantryText("These saved receipts share the store, purchase day and printed food wording. Check which purchase this is."))
            if prompt.truncated { Text(pantryText("Only the first eight possible receipts are shown. Check Receipt history if yours is missing.")) }
            ForEach(prompt.candidates) { candidate in
                let first = candidate.original.first
                let title = [first?.merchant, first?.purchaseDate.formatted(date: .abbreviated, time: .omitted),
                    first?.transactionReference ?? String(candidate.id.uuidString.suffix(8))].compactMap { $0 }.joined(separator: " · ")
                Button(title) {
                    selected = candidate.id
                    var initial: [Int: UUID] = [:]
                    for row in prompt.rows {
                        if prompt.fixed[row.ordinal] == nil, let matches = candidate.matches[row.ordinal], matches.count == 1,
                           !prompt.fixed.values.contains(matches[0]),
                           candidate.matches.values.filter({ $0.contains(matches[0]) }).count == 1 {
                            initial[row.ordinal] = matches[0]
                        }
                    }
                    links = initial
                }.accessibilityIdentifier("receipt.rescan.candidate.\(candidate.id)")
                if selected == candidate.id {
                    Text(pantryText("Previously confirmed lines")).font(.headline)
                    ForEach(candidate.original) { fact in
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
                    NavigationLink(pantryText("Open original receipt and price corrections")) {
                        PantryReceiptHistory(model: model, receiptID: candidate.id, permittedLines: Set(candidate.original.map(\.lineID)))
                    }
                    Text(pantryText("Selected lines on this document")).font(.headline)
                    ForEach(prompt.rows) { row in
                        VStack(alignment: .leading) {
                            Text(verbatim: row.original)
                            Text(verbatim: row.name)
                            if row.treatment == .add { Text(pantryLocationName(row.location)) }
                            Text(pantryFormat("Received %@", row.received + " " + pantryUnit(row.unit)))
                            Text(pantryFormat("Usable %@", row.usable + " " + pantryUnit(row.unit)))
                            if !row.paid.isEmpty { Text(pantryFormat("Paid line total %@", row.paid)) }
                            let matches = candidate.matches[row.ordinal] ?? []
                            if prompt.fixed[row.ordinal] != nil {
                                Text(pantryText("Previously saved on this receipt."))
                            } else if matches.isEmpty {
                                Text(pantryText("New selected line on this receipt"))
                            } else {
                                Picker(pantryText("Match this printed line"), selection: Binding(get: { links[row.ordinal] }, set: { links[row.ordinal] = $0 })) {
                                    Text(pantryText("Additional line")).tag(UUID?.none)
                                    ForEach(candidate.original.filter { matches.contains($0.id) }) { old in
                                        Text(old.name + " · " + pantryQuantity(old.received) + " · " + String(old.lineID.uuidString.suffix(8))).tag(Optional(old.id))
                                    }
                                }
                            }
                        }
                    }
                    Button(pantryText("Review against this original")) {
                        choose(.init(basis: prompt.basis, receipt: candidate.id, existingByOrdinal: links))
                    }.accessibilityIdentifier("receipt.rescan.original")
                }
            }
            if prompt.linkedReceipt == nil {
                Button(pantryText("This is a separate purchase")) {
                    choose(.init(basis: prompt.basis, receipt: nil, existingByOrdinal: [:]))
                }.accessibilityIdentifier("receipt.rescan.separate")
            }
            Button(pantryText("Edit selected lines"), action: edit)
        }
    }
}
