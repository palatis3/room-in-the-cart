import SwiftUI
import HouseholdClient

/// Placed before adjacent individual inbox rows. It labels a possible overlap;
/// opening and deciding each request still uses the existing independent flow.
struct RequestDuplicateGroupHeading: View {
    let group: RequestDuplicateGroup
    var body: some View {
        if group.hasPossibleDuplicates {
            VStack(alignment: .leading, spacing: 6) {
                Label(requestDuplicateText("Compare these requests"), systemImage: "square.on.square")
                    .font(.headline)
                Text(requestDuplicateText("The names match. Check each person's amount and use before deciding."))
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("household.duplicates.group.\(group.requests.first?.id ?? group.id)")
        }
    }
}

/// Compare request evidence and prefill the existing shopper decision for explicit review.
struct RequestDuplicateComparisonSection: View {
    @ObservedObject var model: HouseholdInboxModel
    let requestID: String
    var sharedShop: HouseholdShopModel? = nil

    var body: some View {
        if model.authorized, let request = model.selected, request.id == requestID,
           let group = model.duplicateRequestGroup(containing: requestID), let shop = model.shop {
            if group.hasPossibleDuplicates || model.nextCursor != nil {
                requestComparison(group)
            }
            if let sharedShop {
                DuplicatePurchasedRequestSection(shop: sharedShop, inbox: model, request: request, group: group)
            }
            if model.canReadFood, model.pending == nil {
                Section {
                    if let needs = model.matchingMealNeeds {
                        if needs.isEmpty {
                            Text(requestDuplicateText("No matching need in the current meal plan."))
                        }
                        ForEach(needs) { need in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(need.fact.sourceLabel).font(.headline)
                                Text(need.fact.originalText)
                                if let amount = need.fact.originalQuantityText { Text(amount) }
                                ForEach(need.fact.sourceExclusions.indices, id: \.self) { index in
                                    Text(need.fact.sourceExclusions[index].label)
                                }
                                if shop.phase == "draft", model.canSelectSameItem(for: request),
                                   RequestDuplicateGrouping.comparisonName(request.originalItem) == RequestDuplicateGrouping.comparisonName(need.fact.originalText) {
                                    Button(requestDuplicateText("Same item as this meal need")) {
                                        Task { await model.selectSameItem(.meal(factId: need.fact.id.uuid, factRevision: need.fact.revision), for: request) }
                                    }.accessibilityIdentifier("household.duplicates.sameMeal." + need.id.string)
                                    Button(requestDuplicateText("Review additional packs")) { model.choice = .add }
                                        .disabled(model.choice == .add)
                                }
                                if let line = need.line, model.availableChoices.contains(.link) {
                                    Button(requestDuplicateText("Use this basket line") + " · " + line.originalItem) {
                                        model.selectDuplicateLine(line, for: request, shopRevision: shop.shopRevision)
                                    }.disabled(model.busy)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Button(requestDuplicateText("Check planned meal needs")) {
                            Task { await model.checkMealNeeds(for: request) }
                        }.disabled(model.busy)
                    }
                } header: {
                    Text(requestDuplicateText("Planned meals"))
                }
            }
            let lines = RequestDuplicateGrouping.basketCandidates(for: group, lines: shop.lines)
            if !lines.isEmpty, model.availableChoices.contains(.link), model.pending == nil {
                Section {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.originalItem).font(.headline)
                            LabeledContent(ht("Whole packs"), value: line.packs.formatted())
                            Button(requestDuplicateText("Use this basket line")) {
                                model.selectDuplicateLine(line, for: request, shopRevision: shop.shopRevision)
                            }
                            .disabled(model.busy || (model.choice == .link && model.linkedLineID == line.id))
                        }
                    }
                    if let requestUUID = UUID(uuidString: request.id), let shopUUID = UUID(uuidString: shop.shopId) {
                        DuplicateAssistanceView(source: .init(id: requestUUID, text: request.originalItem),
                            candidates: lines.compactMap { line in
                                UUID(uuidString: line.id).map { .init(id: $0, text: line.originalItem) }
                            }, family: .init(shopID: shopUUID, shopRevision: shop.shopRevision,
                                            authorityEpoch: shop.authorityEpoch, requestRevision: request.revision),
                            authorized: {
                                model.authorized && !model.busy && model.pending == nil && model.selected == request &&
                                model.shop == shop && model.availableChoices.contains(.link)
                            }, familyHouseholdID: model.householdID, familyMemberID: model.memberID) { id in
                                guard let line = lines.first(where: { UUID(uuidString: $0.id) == id }) else { return }
                                model.selectDuplicateLine(line, for: request, shopRevision: shop.shopRevision)
                            }
                    }
                    Button(requestDuplicateText("Review additional packs")) {
                        model.choice = .add
                    }
                    .disabled(model.busy || model.choice == .add)
                } header: {
                    Text(requestDuplicateText("Already in this basket"))
                }
            }
        }
    }

    private func requestComparison(_ group: RequestDuplicateGroup) -> some View {
        Section {
            if group.hasPossibleDuplicates {
                Text(requestDuplicateText("Does one pack cover these uses, or is another needed? Compare the original requests, then decide each one separately."))
                    .foregroundStyle(Theme.secondary)
            } else {
                Text(requestDuplicateText("No matching name among the loaded requests yet. Other requests have not been checked."))
                    .foregroundStyle(Theme.secondary)
            }
            Text(requestDuplicateText("Comparing changes nothing. Quantities are not added together. Each requester keeps a separate outcome."))
                .font(.footnote).foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("household.duplicates.separateOutcomes")
            ForEach(group.requests) { request in
                RequestDuplicateComparisonRow(request: request, isSelected: request.id == requestID)
                if model.canCompareOpenRequest(request) {
                    RequestPairActions(model: model, other: request)
                }
            }
            if model.nextCursor != nil {
                Text(requestDuplicateText("Only the loaded requests are shown. Check more requests to inspect the remaining pages."))
                    .font(.footnote).foregroundStyle(Theme.secondary)
                Button(requestDuplicateText("Check more requests")) {
                    Task { await model.load(more: true) }
                }
                .disabled(model.busy || model.pending != nil)
                .accessibilityIdentifier("household.duplicates.loadMore")
            }
        } header: {
            Text(requestDuplicateText("Compare matching requests"))
                .accessibilityIdentifier("household.duplicates.comparison")
        }
    }
}

private extension RequestPairRelationship {
    var title: String {
        switch self {
        case .sameItem: return requestDuplicateText("Same item")
        case .additionalQuantity: return requestDuplicateText("Additional quantity")
        }
    }
}

private struct RequestPairActions: View {
    @ObservedObject var model: HouseholdInboxModel
    let other: OwnRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pair = model.reviewedPair(with: other) {
                LabeledContent(requestDuplicateText("Reviewed comparison"), value: pair.relationship.title)
                Button(requestDuplicateText("Undo comparison")) {
                    Task { await model.reviewRequestPairUndo(with: other) }
                }
                .accessibilityIdentifier("household.duplicates.pair.undo." + other.id)
            } else {
                Button(requestDuplicateText("Same item")) {
                    Task { await model.reviewRequestPair(with: other, relationship: .sameItem) }
                }
                .accessibilityIdentifier("household.duplicates.pair.same." + other.id)
                Button(requestDuplicateText("Additional quantity")) {
                    Task { await model.reviewRequestPair(with: other, relationship: .additionalQuantity) }
                }
                .accessibilityIdentifier("household.duplicates.pair.additional." + other.id)
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.busy || model.pending != nil || model.preview != nil)
    }
}

struct RequestPairPreview: View {
    let selected: OwnRequest
    let evidence: RequestPairEvidence
    let undo: Bool

    var body: some View {
        Text(undo ? requestDuplicateText("Undo comparison") : evidence.relationship.title).font(.title2)
        LabeledContent(selected.authorAlias ?? requestDuplicateText("Alias unavailable"), value: selected.originalItem)
        Text(selected.ownQuantity ?? requestDuplicateText("No amount or use supplied"))
        LabeledContent(evidence.authorAlias, value: evidence.item)
        Text(evidence.quantity ?? requestDuplicateText("No amount or use supplied"))
        Text(requestDuplicateText("Both requests stay open. Review the packs to buy separately."))
    }
}

private struct RequestDuplicateComparisonRow: View {
    let request: OwnRequest
    let isSelected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isSelected ? requestDuplicateText("Deciding this request") : requestDuplicateText("Other request"))
                .font(.headline)
                .accessibilityIdentifier("household.duplicates.selection.\(request.id)")
            LabeledContent(requestDuplicateText("Requested by"), value: request.authorAlias ?? requestDuplicateText("Alias unavailable"))
                .accessibilityIdentifier("household.duplicates.author.\(request.id)")
            VStack(alignment: .leading, spacing: 4) {
                Text(requestDuplicateText("Original request")).font(.caption).foregroundStyle(Theme.secondary)
                Text(request.originalItem).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("household.duplicates.original.\(request.id)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(requestDuplicateText("Amount and use, as written")).font(.caption).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("household.duplicates.amountLabel.\(request.id)")
                Text(request.ownQuantity ?? requestDuplicateText("No amount or use supplied"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("household.duplicates.amount.\(request.id)")
            }
            LabeledContent(requestDuplicateText("Destination"), value: destination)
            LabeledContent(requestDuplicateText("Request revision"), value: request.revision.formatted())
            LabeledContent(requestDuplicateText("Received"), value: householdTime(request.receivedAt))
            LabeledContent(requestDuplicateText("This request's outcome"), value: shopperRequestStatus(request))
                .accessibilityIdentifier("household.duplicates.outcome.\(request.id)")
            if let outcome = request.purchaseOutcome {
                Text(purchaseStatus(outcome))
                    .accessibilityIdentifier("household.duplicates.purchase.\(request.id)")
            }
            if let clarification = request.clarification {
                VStack(alignment: .leading, spacing: 4) {
                    Text(requestDuplicateText("Clarification for this requester")).font(.caption).foregroundStyle(Theme.secondary)
                    Text(clarification).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
    private var destination: String {
        switch request.route {
        case "current": return requestDuplicateText("This shop")
        case "next": return requestDuplicateText("Next shop")
        default: return requestDuplicateText("Destination unavailable")
        }
    }
}

func requestDuplicateText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "RequestDuplicates")
}
