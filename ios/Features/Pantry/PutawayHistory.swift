import CoreDomain
import LocalStore
import SwiftUI

func putawayText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "ReceiptPutaway")
}

func putawayActionTitle(_ count: Int) -> String {
    switch count {
    case 0: return putawayText("Save receipt decisions")
    case 1: return putawayText("Put away 1 item")
    default: return String(format: putawayText("Put away %lld items"), locale: .current, Int64(count))
    }
}

/// Printed wording stays selectable and scales with Dynamic Type, including on long receipts.
struct ReceiptPaperLine: View {
    let wording: String
    var provenance: String? = nil
    var title = pantryText("Printed line")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text(verbatim: wording)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            if let provenance {
                Text(verbatim: provenance).font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .padding(.bottom, 3)
        .background(Theme.canvas, in: ReceiptPaperEdge())
    }
}

private struct ReceiptPaperEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 2))
        for x in stride(from: rect.maxX, to: rect.minX, by: -10) {
            path.addLine(to: CGPoint(x: max(rect.minX, x - 5), y: rect.maxY))
            path.addLine(to: CGPoint(x: max(rect.minX, x - 10), y: rect.maxY - 2))
        }
        path.closeSubpath()
        return path
    }
}

struct ReceiptIntactToggle: View {
    @Binding var line: ReceiptImportDraft.Line
    let lots: [InventoryLot]

    var body: some View {
        Button {
            if line.treatment == .skip {
                line.selectIntact(deliveries: lots)
            } else if line.selectedIntact {
                line.selectedIntact = false
                line.treatment = .skip
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(verbatim: line.name).font(.headline)
                    Text(amountAndDestination).font(.subheadline).monospacedDigit().foregroundStyle(Theme.secondary)
                }
            } icon: {
                Image(systemName: line.selectedIntact ? "checkmark.circle.fill" : "circle")
            }.frame(minHeight: 44)
        }
        .disabled(line.treatment != .skip && !line.selectedIntact)
        .accessibilityValue(line.selectedIntact ? putawayText("Selected intact") :
                            line.treatment == .skip ? putawayText("Unselected") : putawayText("Reviewed individually"))
        .accessibilityIdentifier("receipt.intact.\(line.ordinal)")
    }

    private var amountAndDestination: String {
        if line.selectedIntact {
            return pantryPrintedQuantity(line.usable, unit: line.unit) + " · " + pantryLocationName(line.location)
        }
        switch line.treatment {
        case .skip:
            guard let quantity = line.printed?.quantity, let unit = line.printed?.unit else { return putawayText("Unselected") }
            return pantryText("Printed quantity") + " · " + pantryPrintedQuantity(quantity, unit: unit)
        case .add: return putawayText("Put this food away")
        case .keptSome: return putawayText("Kept some")
        case .eaten: return putawayText("Ate this")
        case .missing: return putawayText("Missing or unusable")
        case .chargeOrReturn: return putawayText("Fee, adjustment or return")
        case .link: return putawayText("Linked to prior delivery")
        }
    }
}

struct ReviewedReceiptHeading: View {
    let header: ReviewedReceiptHeader
    private(set) var dates = ReceiptDateDisplay()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: header.merchant).marketJournalTitle(.title2)
            Text(dates.purchaseDay(header.date)).font(.subheadline).foregroundStyle(Theme.secondary)
            if let reference = header.reference { Text(verbatim: reference) }
            if let cents = header.totalMinor {
                LabeledContent(putawayText("Paid receipt total")) {
                    Text(verbatim: receiptMoney(Money(minorUnits: cents)))
                        .fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.ink)
                }
            } else {
                Text(putawayText("Paid receipt total unknown"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PutawayDecisionLabel: View {
    let row: ReviewedReceiptDecision
    private var label: String {
        switch row.kind {
        case .eaten: putawayText("Ate this")
        case .missing: putawayText("Missing or unusable")
        case .chargeOrReturn: putawayText("Fee, adjustment or return")
        case .stored: putawayText("Put away")
        case .keptSome: putawayText("Kept some")
        case .linked: putawayText("Linked to prior delivery")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: row.name).font(.headline)
            Text(label)
            if row.lotID == nil { Text(putawayText("No stock added")).foregroundStyle(Theme.secondary) }
            if row.kind == .linked, let lotID = row.lotID {
                Text(pantryFormat("Link delivery: %@ · %@", row.name, String(lotID.uuidString.suffix(8))))
            }
            if let paid = row.paidMinor { Text(pantryFormat("Paid line total %@", receiptMoney(Money(minorUnits: paid)))).monospacedDigit() }
            else { Text(pantryText("Paid price unknown")) }
            ReceiptPaperLine(wording: row.original)
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}

struct PutawayOverlapReview: View {
    let prompt: PutawayOverlap
    let choose: (PutawayOverlap.Choice) -> Void
    let edit: () -> Void

    var body: some View {
        Section(putawayText("Check a repeated receipt line")) {
            Text(putawayText("This wording appears in an earlier review of this purchase. Check the original lines before adding another."))
            PutawayDecisionLabel(row: prompt.line)
        }
        Section(putawayText("Previously reviewed")) {
            ForEach(prompt.earlier) { old in
                PutawayDecisionLabel(row: old)
                if prompt.canUse(old) {
                    Button(putawayText("Use this saved decision")) { choose(.earlier(old.id)) }
                }
            }
            Button(putawayText("This is an additional printed line")) { choose(.additional) }
            Button(pantryText("Edit receipt lines"), action: edit)
        }
    }
}

struct PutawayHistory: View {
    @ObservedObject var model: PantryModel
    @State private var headers: [ReviewedReceiptHeader] = []
    @State private var more = true
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        List {
            if model.canEdit {
                ForEach(headers) { header in
                    NavigationLink { PutawayHistoryDetail(model: model, header: header) } label: {
                        ReviewedReceiptHeading(header: header)
                    }
                    .listRowBackground(Theme.surface)
                }
                if failed { Text(putawayText("Could not load receipt decisions.")) }
                if headers.isEmpty && !more { Text(putawayText("No reviewed purchases yet.")) }
                if more {
                    Button(pantryText("Load receipt lines")) { Task { await load() } }.disabled(busy)
                }
            }
        }
        .workingSurface().privacySensitive()
        .navigationTitle(putawayText("Reviewed purchases"))
        .task(id: model.snapshot?.state.workspaceID) { headers = []; more = true; await load() }
    }

    private func load() async {
        guard !busy, more, model.canEdit else { return }
        busy = true
        defer { busy = false }
        do {
            let next = try await model.reviewedReceiptHeaders(after: headers.last?.id)
            headers += next
            more = next.count == 30
            failed = false
        } catch { failed = true }
    }
}

private struct PutawayHistoryDetail: View {
    @ObservedObject var model: PantryModel
    let header: ReviewedReceiptHeader
    @State private var rows: [ReviewedReceiptDecision] = []
    @State private var more = true
    @State private var busy = false
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.canEdit {
                ReviewedReceiptHeading(header: header).listRowBackground(Theme.surface)
                let token = model.generation
                ReceiptCouponReviewLink(source: .purchase(model, header), pickupID: nil, authorize: {
                    model.permitsReceiptSource && model.generation == token
                })
                ForEach(rows.sorted { $0.ordinal < $1.ordinal }) { row in
                    PutawayDecisionLabel(row: row).listRowBackground(Theme.surface)
                }
                if rows.contains(where: { $0.lotID != nil }) {
                    NavigationLink(putawayText("Pantry quantities and price revisions")) {
                        PantryReceiptHistory(model: model, receiptID: header.id, showsDone: false)
                    }
                }
                if failed { Text(putawayText("Could not load receipt decisions.")) }
                if more {
                    Button(pantryText("Load receipt lines")) { Task { await load() } }.disabled(busy)
                }
            }
        }
        .workingSurface().privacySensitive()
        .navigationTitle(putawayText("Receipt decisions"))
        .task { await load() }
        .onChange(of: model.snapshot?.state.workspaceID) { _, _ in rows = []; dismiss() }
    }

    private func load() async {
        guard !busy, more, model.canEdit else { return }
        busy = true
        defer { busy = false }
        do {
            let page = try await model.reviewedReceiptDecisions(header.id, after: rows.last?.id)
            rows += page
            more = page.count == 50
            failed = false
        } catch { failed = true }
    }
}
