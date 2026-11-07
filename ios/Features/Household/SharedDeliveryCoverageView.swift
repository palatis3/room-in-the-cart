import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedDeliveryCoverageView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
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
                            if (page.recoveryRevision ?? 0) > 0 {
                                Text(sharedRecoveryText("Use the current meal plan for new cook instructions."))
                                if model.canReadCookCopies {
                                    NavigationLink(pTr("Saved cook notes")) {
                                        SharedCookHistoryView(model: model, household: household, page: page, occurrence: occurrence)
                                    }
                                }
                            } else {
                                NavigationLink(pTr("Preview a dated cook instruction")) {
                                    SharedDeliveryCookView(model: model, household: household, page: page, coverage: .delivery(result), occurrence: occurrence)
                                }
                                .accessibilityIdentifier("delivery.cook." + occurrence.id.uuidString)
                            }
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

struct SharedDeliveryCookView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedDeliveryPage
    let coverage: SharedCookCoverage
    let occurrence: SharedMealOccurrence
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

    private struct WordingReview {
        let presentation: UUID
        let language, text: String

        func matches(_ id: UUID, _ currentLanguage: String, _ currentText: String) -> Bool {
            presentation == id && language == currentLanguage && text.utf8.elementsEqual(currentText.utf8)
        }
    }
    private enum ReviewAction { case read(WordingReview?), share, save }
    @State private var privacyReview: WordingReview?
    @State private var savedWording: [String: String] = [:]

    private struct DatedCopy: Identifiable {
        let id = UUID()
        let text: String
    }

    private var allowed: Bool {
        if case let .recovered(record, _, _) = coverage {
            guard model.canReadMealRecovery, model.recoveryRecord == record else { return false }
        } else if (page.recoveryRevision ?? 0) > 0 { return false }
        if let pantry = coverage.reviewedPantry, !model.canReadPantry || model.pantryRecord != pantry { return false }
        return !household.locked && household.sharedShop === model && model.canReadDelivery &&
        model.scope.shopId.flatMap(UUID.init(uuidString:)) == page.shopId && model.shop?.shopId == model.scope.shopId &&
        model.deliveryRecord == page && model.shop?.shopRevision == page.shopRevision &&
        model.shop?.authorityEpoch == page.authorityEpoch
    }
    private var refreshMessage: String {
        coverage.reviewedPantry == nil ? ht("Refresh deliveries and review the current record.") :
            String(localized: "Review the current pantry and delivery records.", table: "DeliveryCook")
    }
    private var text: String { wording[language] ?? original ?? "" }
    private var canReview: Bool { allowed && model.pending == nil && !model.busy && !stale && !checking && scenePhase == .active && original != nil }

    var body: some View {
        Form {
            if allowed && !stale {
                Picker(pTr("Recipient language"), selection: $language) {
                    Text(pTr("English (US)")).tag("en-US")
                    Text(pTr("Español (EE. UU.)")).tag("es-US")
                }
                if original != nil {
                    Section(ht("Recipient preview")) {
                        if editing {
                            TextEditor(text: Binding(get: { text }, set: { wording[language] = $0 }))
                                .frame(minHeight: 190)
                                .accessibilityLabel(pTr("Editable cook instruction"))
                        } else if let readback {
                            CookReadbackView(instruction: readback) { candidate, _ in
                                canReview && self.readback == candidate && text.utf8.elementsEqual(candidate.text.utf8)
                            }.id(readback.authorityBindingID)
                        } else {
                            Text(verbatim: text).textSelection(.enabled).accessibilityIdentifier("delivery.cook.preview")
                        }
                        if !editing {
                            Button(ht("Edit cook wording")) { cancelReview(); editing = true }
                            if readback == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? CaptureLimits.validate(text)) != nil {
                                if let review = privacyReview {
                                    Text(ht("Review this wording for anyone who can hear it. Remove private budget details before confirming."))
                                    Button(ht("Confirm this copy has no private budget details")) {
                                        Task { await self.review(.read(review)) }
                                    }
                                    .disabled(!canReview)
                                    .accessibilityIdentifier("delivery.cook.confirmReadback")
                                    Button(ht("Cancel"), role: .cancel) { cancelReview() }
                                        .accessibilityIdentifier("delivery.cook.cancelReadback")
                                } else {
                                    Button(ht("Prepare readback")) {
                                        if let original, text.utf8.elementsEqual(original.utf8) {
                                            Task { await review(.read(nil)) }
                                        } else {
                                            privacyReview = WordingReview(presentation: presentation, language: language, text: text)
                                        }
                                    }
                                    .disabled(!canReview)
                                    .accessibilityIdentifier("delivery.cook.prepareReadback")
                                }
                            }
                        }
                    }
                    if !editing {
                        Button(ht("Share dated copy")) { Task { await review(.share) } }
                            .disabled(!canReview || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("delivery.cook.share")
                        if model.canReadCookCopies {
                            Button(pTr("Save dated copy")) { Task { await review(.save) } }
                                .disabled(!canReview || !canSaveWording || savedWording[language] == text)
                                .accessibilityIdentifier("delivery.cook.save")
                            if !canSaveWording && text.utf16.count > 16_000 {
                                Text(ht("Shorten the wording to save a version. The full dated copy can still be shared."))
                            } else if savedWording[language] == text {
                                Text(ht("Dated copy saved"))
                            }
                        }
                        if checking { ProgressView() }
                        if let notice = model.notice { Text(notice) }
                        if retry {
                            Text(coverage.reviewedPantry == nil ? ht("Couldn’t check the delivery. Reconnect and try again.") :
                                    String(localized: "Couldn’t check food coverage. Reconnect and try again.", table: "DeliveryCook"))
                        }
                        if let lifecycle = household.lifecycle, lifecycle.canShare {
                            NavigationLink(pTr("Prepare a current shared view")) { HouseholdHelperComposer(model: lifecycle) }
                        }
                    }
                } else {
                    Text(refreshMessage)
                }
            } else {
                Text(refreshMessage)
            }
            if model.canReadCookCopies && !household.locked && household.sharedShop === model {
                NavigationLink(pTr("Saved cook notes")) {
                    SharedCookHistoryView(model: model, household: household, page: page, occurrence: occurrence)
                }
                .accessibilityIdentifier("delivery.cook.history")
            }
        }
        .navigationTitle(pTr("Tell the cook"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ht("Done")) { editing = false }
                        .accessibilityIdentifier("delivery.cook.finishEditing")
                }
            }
        }
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
        privacyReview = nil
        readback = nil
    }

    private func prepare() {
        cancelReview()
        retry = false
        editing = false
        original = SharedDeliveryCookDraft.make(page: page, report: coverage, occurrence: occurrence, language: language)
    }

    private func clear() {
        cancelReview()
        sharing = nil
        original = nil
        wording = [:]
    }

    private var canSaveWording: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 16_000
    }

    private func review(_ action: ReviewAction) async {
        guard canReview, !editing else { return }
        let reviewedLanguage = language, reviewedText = text, reviewID = presentation
        if case .read(let confirmation) = action {
            if let confirmation {
                guard privacyReview?.matches(reviewID, reviewedLanguage, reviewedText) == true,
                      confirmation.matches(reviewID, reviewedLanguage, reviewedText) else { return }
            } else {
                guard let original, reviewedText.utf8.elementsEqual(original.utf8) else { return }
            }
        }
        privacyReview = nil
        retry = false
        checking = true
        defer { checking = false }
        do {
            let unchanged: Bool
            switch coverage {
            case let .recovered(record, reviewed, meal):
                let current = try await model.effectiveCoverage(reviewed: record)
                unchanged = current.needs.filter { $0.occurrenceId == meal.id } == reviewed.needs.filter { $0.occurrenceId == meal.id } &&
                    current.unplannedOccurrenceIds.contains(meal.id) == reviewed.unplannedOccurrenceIds.contains(meal.id)
            case .delivery(let reviewed):
                let current = try await model.coverage(reviewed: page)
                unchanged = current.needs.filter { $0.occurrenceId == occurrence.id } == reviewed.needs.filter { $0.occurrenceId == occurrence.id }
                    && current.unplannedOccurrenceIds.contains(occurrence.id) == reviewed.unplannedOccurrenceIds.contains(occurrence.id)
            case let .food(pantry, reviewed):
                let current = try await model.foodCoverage(reviewed: pantry, delivery: page)
                unchanged = current.pantryRevision == reviewed.pantryRevision &&
                    current.needs.filter { $0.occurrenceId == occurrence.id } == reviewed.needs.filter { $0.occurrenceId == occurrence.id }
                    && current.unplannedOccurrenceIds.contains(occurrence.id) == reviewed.unplannedOccurrenceIds.contains(occurrence.id)
            }
            guard reviewID == presentation else { return }
            guard unchanged else {
                stale = true; clear(); return
            }
            guard allowed, model.pending == nil, !model.busy, scenePhase == .active, !editing, language == reviewedLanguage, text.utf8.elementsEqual(reviewedText.utf8) else { return }
            readback = nil
            switch action {
            case .share:
                sharing = DatedCopy(text: reviewedText)
            case .save:
                guard model.canReadCookCopies, canSaveWording, savedWording[reviewedLanguage] != reviewedText else { return }
                let locale = reviewedLanguage == "es-US" ? "es" : "en"
                let facts = SharedDeliveryCookDraft.instruction(page: page, report: coverage, occurrence: occurrence,
                                                            language: reviewedLanguage)?.factIndex(for: reviewedText)
                let saved: Bool
                if case let .recovered(record, _, meal) = coverage {
                    saved = await model.saveCookCopy(text: reviewedText, language: locale, facts: facts, meal: meal, reviewed: record)
                } else {
                    saved = await model.saveCookCopy(text: reviewedText, language: locale, facts: facts, occurrence: occurrence, reviewed: page, pantry: coverage.reviewedPantry)
                }
                if saved && allowed && reviewID == presentation {
                    savedWording[reviewedLanguage] = reviewedText
                }
            case .read:
                guard let checkedAt = serviceDate(coverage.asOf) else { return }
                readback = CookReadbackInstruction(authorityBindingID: UUID(), sourceID: occurrence.id,
                    sourceRevision: Int64(page.recoveryRevision.flatMap { $0 > 0 ? $0 : nil } ?? page.supplyRevision), createdAt: checkedAt, startBefore: Date().addingTimeInterval(60),
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
