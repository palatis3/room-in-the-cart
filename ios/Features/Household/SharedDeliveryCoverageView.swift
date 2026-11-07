import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedDeliveryCoverageView: View {
    @ObservedObject var model: HouseholdShopModel
    let page: SharedDeliveryPage
    @Environment(\.dismiss) private var dismiss
    @State private var result: SharedDeliveryCoverage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let result, result.shopId == page.shopId, result.placedRevision == page.placedRevision,
                   result.supplyRevision == page.supplyRevision, result.authorityEpoch == page.authorityEpoch, result.shopRevision == page.shopRevision {
                    Section {
                        if let date = serviceDate(result.asOf) {
                            LabeledContent(ht("Checked at"), value: date.formatted())
                        }
                    } footer: {
                        Text(ht("These counts use confirmed deliveries for this order. Protected portions are counted first."))
                    }
                    ForEach(page.meals ?? []) { occurrence in
                        Section {
                            if let planning = occurrence.meal.planning { SharedMealPreparationFacts(planning: planning) }
                            if result.unplannedOccurrenceIds.contains(occurrence.id) {
                                Text(ht("This meal has no recorded ingredient requirements."))
                            }
                            ForEach(Array(result.needs.filter { $0.occurrenceId == occurrence.id }.enumerated()), id: \.offset) { _, need in
                                requirement(need, occurrence: occurrence)
                            }
                            NavigationLink(pTr("Preview a dated cook instruction")) {
                                SharedDeliveryCookView(model: model, page: page, coverage: result, occurrence: occurrence)
                            }
                            .accessibilityIdentifier("delivery.cook." + occurrence.id.uuidString)
                        } header: { Text(occurrence.meal.title + " · " + occurrence.meal.day) }
                    }
                } else if failed {
                    Text(ht("Refresh deliveries and review the current record."))
                    Button(ht("Refresh deliveries")) {
                        Task {
                            await model.load()
                            await model.loadDelivery()
                            if model.deliveryRecord == page { await load(page) }
                        }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(ht("Delivered food by meal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ht("Done")) { dismiss() } } }
            .task(id: page) { await load(page) }
        }
    }

    private func load(_ reviewed: SharedDeliveryPage) async {
        do {
            let updated = try await model.coverage(reviewed: reviewed)
            guard !Task.isCancelled else { return }
            result = updated; failed = false
        } catch {
            guard !Task.isCancelled else { return }
            result = nil; failed = true
        }
    }

    @ViewBuilder private func requirement(_ need: SharedDeliveryCoverage.Need, occurrence: SharedMealOccurrence) -> some View {
        if let plan = occurrence.meal.planning, let ingredient = plan.ingredients.first(where: { $0.id == need.ingredientId }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ingredient.name).font(.headline)
                let ingredientRules = ingredient.exclusions.filter { !(plan.exclusions ?? []).contains($0) }
                if !ingredientRules.isEmpty {
                    LabeledContent(ht("Ingredient exclusions"), value: ingredientRules.joined(separator: ", "))
                }
                if need.protected { Label(ht("Protected portions"), systemImage: "lock") }
                let groups = plan.groups.filter { need.groupIds.contains($0.id) }.map(\.name)
                if !groups.isEmpty { Text(groups.joined(separator: ", ")) }
                LabeledContent(ht("Ingredient quantity"), value: deliveryQuantityText(need.required))
                if let unit = need.required.flatMap({ UnitOfMeasure(rawValue: $0.unit) }), let covered = need.covered, let missing = need.missing {
                    LabeledContent(ht("Covered by deliveries"), value: quantity(covered, unit: unit))
                    LabeledContent(ht("Uncovered by deliveries"), value: quantity(missing, unit: unit))
                    ForEach(need.reservations ?? [], id: \.reservationId) { reservation in
                        if let source = page.sources.first(where: { $0.id == reservation.sourceId }) {
                            VStack(alignment: .leading) {
                                Text(source.foodName + " · " + source.segmentKey.uuidString.prefix(8)).font(.subheadline)
                                LabeledContent(ht("Amount set aside"), value: quantity(reservation.requested, unit: unit))
                                LabeledContent(ht("Still backed by this delivery"), value: quantity(reservation.backed, unit: unit))
                            }
                        }
                    }
                    ForEach(need.allocations, id: \.sourceId) { allocation in
                        if let source = page.sources.first(where: { $0.id == allocation.sourceId }) {
                            LabeledContent(source.foodName + " · " + source.segmentKey.uuidString.prefix(8), value: quantity(allocation.amount, unit: unit))
                        }
                    }
                }
                ForEach(need.issues, id: \.self) { code in Text(ht(SharedDeliveryCookDraft.issueKey(code))).font(.footnote) }
            }
            .padding(.vertical, 4)
        }
    }

    private func quantity(_ fraction: SharedDeliveryCoverage.Fraction, unit: UnitOfMeasure) -> String {
        let single = fraction.numerator == "1" && fraction.denominator == "1"
        let label = unit == .count && !single ? dinnerText("units") : dinnerUnit(unit, singular: single)
        return fraction.formatted + " " + label
    }

}

private struct SharedDeliveryCookView: View {
    @ObservedObject var model: HouseholdShopModel
    let page: SharedDeliveryPage
    let coverage: SharedDeliveryCoverage
    let occurrence: SharedMealOccurrence
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var language = Bundle.main.preferredLocalizations.first?.hasPrefix("es") == true ? "es-US" : "en-US"
    @State private var original: String?
    @State private var wording: [String: String] = [:]
    @State private var editing = false
    @State private var checking = false
    @State private var stale = false
    @State private var retry = false
    @State private var presentation = UUID()
    @State private var readback: CookReadbackInstruction?
    @State private var sharing: DatedCopy?

    private struct DatedCopy: Identifiable {
        let id = UUID()
        let text: String
    }

    private var allowed: Bool {
        !household.locked && household.sharedShop === model && model.canReadDelivery && model.pending == nil &&
        model.deliveryRecord == page && model.shop?.shopRevision == page.shopRevision &&
        model.shop?.authorityEpoch == page.authorityEpoch
    }
    private var text: String { wording[language] ?? original ?? "" }
    private var canReview: Bool { allowed && !stale && !checking && scenePhase == .active && original != nil }

    var body: some View {
        Form {
            if allowed && !stale {
                Picker(pTr("Recipient language"), selection: $language) {
                    Text(pTr("English (US)")).tag("en-US")
                    Text(pTr("Español (EE. UU.)")).tag("es-US")
                }
                if let original {
                    Section(ht("Recipient preview")) {
                        if editing {
                            TextEditor(text: Binding(get: { text }, set: { wording[language] = $0 }))
                                .frame(minHeight: 190)
                                .accessibilityLabel(pTr("Editable cook instruction"))
                            Button(ht("Done")) { editing = false }
                        } else if let readback {
                            CookReadbackView(instruction: readback) { candidate, _ in
                                canReview && self.readback == candidate && text == candidate.text && text == original
                            }.id(readback.authorityBindingID)
                        } else {
                            Text(verbatim: text).textSelection(.enabled).accessibilityIdentifier("delivery.cook.preview")
                        }
                        if !editing {
                            Button(ht("Edit cook wording")) { readback = nil; editing = true }
                            if readback == nil && text == original && (try? CaptureLimits.validate(text)) != nil {
                                Button(ht("Prepare readback")) { Task { await review(share: false) } }
                                    .disabled(!canReview)
                            }
                        }
                    }
                    if !editing {
                        Button(ht("Share dated copy")) { Task { await review(share: true) } }
                            .disabled(!canReview || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("delivery.cook.share")
                        if checking { ProgressView() }
                        if retry { Text(ht("Couldn’t check the delivery. Reconnect and try again.")) }
                        if let lifecycle = household.lifecycle, lifecycle.canShare {
                            NavigationLink(pTr("Prepare a current shared view")) { HouseholdHelperComposer(model: lifecycle) }
                        }
                    }
                } else {
                    Text(ht("Refresh deliveries and review the current record."))
                }
            } else {
                Text(ht("Refresh deliveries and review the current record."))
            }
        }
        .navigationTitle(pTr("Tell the cook"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { prepare() }
        .onChange(of: language) { _, _ in prepare() }
        .onChange(of: allowed) { _, current in if !current { clear() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancelReview() } }
        .onDisappear { cancelReview() }
        .sheet(item: $sharing) { copy in
            if allowed { PickupActivitySheet(text: copy.text) { _, _ in sharing = nil } }
        }
    }

    private func cancelReview() {
        presentation = UUID()
        readback = nil
    }

    private func prepare() {
        cancelReview()
        retry = false
        editing = false
        original = SharedDeliveryCookDraft.make(page: page, coverage: coverage, occurrence: occurrence, language: language)
    }

    private func clear() {
        sharing = nil
        readback = nil
        original = nil
        wording = [:]
    }

    private func review(share: Bool) async {
        guard canReview, !editing else { return }
        let reviewedLanguage = language, reviewedText = text, reviewID = presentation
        retry = false
        checking = true
        defer { checking = false }
        do {
            let current = try await model.coverage(reviewed: page)
            guard reviewID == presentation else { return }
            guard current.needs.filter({ $0.occurrenceId == occurrence.id }) == coverage.needs.filter({ $0.occurrenceId == occurrence.id }),
                  current.unplannedOccurrenceIds.contains(occurrence.id) == coverage.unplannedOccurrenceIds.contains(occurrence.id) else {
                stale = true; clear(); return
            }
            guard allowed, scenePhase == .active, !editing, language == reviewedLanguage, text == reviewedText else { return }
            readback = nil
            if share {
                sharing = DatedCopy(text: reviewedText)
            } else if reviewedText == original, let checkedAt = serviceDate(coverage.asOf) {
                readback = CookReadbackInstruction(authorityBindingID: UUID(), sourceID: occurrence.id,
                    sourceRevision: Int64(page.supplyRevision), createdAt: checkedAt, startBefore: Date().addingTimeInterval(60),
                    text: reviewedText, localeIdentifier: reviewedLanguage, excludesPrivateBudget: true)
            }
        } catch {
            guard reviewID == presentation else { return }
            switch error as? ClientError {
            case .transport, .service(status: 429, code: _, correlationID: _, retryAfter: _):
                retry = true
            case let .service(status, _, _, _) where status >= 500:
                retry = true
            default:
                stale = true
                clear()
            }
        }
    }
}
