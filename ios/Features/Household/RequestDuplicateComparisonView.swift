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
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("household.duplicates.group.\(group.requests.first?.id ?? group.id)")
        }
    }
}

/// Read-only context inside the existing decision Form. The model remains the
/// sole owner of the selected request; this view cannot edit or submit anything.
struct RequestDuplicateComparisonSection: View {
    @ObservedObject var model: HouseholdInboxModel
    let requestID: String

    var body: some View {
        if model.authorized,
           let group = model.duplicateRequestGroup(containing: requestID),
           group.hasPossibleDuplicates || model.nextCursor != nil {
            Section {
                if group.hasPossibleDuplicates {
                    Text(requestDuplicateText("Does one pack cover these uses, or is another needed? Compare the original requests, then decide each one separately."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(requestDuplicateText("No matching name among the loaded requests yet. Other requests have not been checked."))
                        .foregroundStyle(.secondary)
                }
                ForEach(group.requests) { request in
                    RequestDuplicateComparisonRow(request: request, isSelected: request.id == requestID)
                }
                Text(requestDuplicateText("Comparing changes nothing. Quantities are not added together. Each requester keeps a separate outcome."))
                    .font(.footnote).foregroundStyle(.secondary)
                if model.nextCursor != nil {
                    Text(requestDuplicateText("Only the loaded requests are shown. Check more requests to inspect the remaining pages."))
                        .font(.footnote).foregroundStyle(.secondary)
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
}

private struct RequestDuplicateComparisonRow: View {
    let request: OwnRequest
    let isSelected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isSelected ? requestDuplicateText("Deciding this request") : requestDuplicateText("Other request"))
                .font(.headline)
            LabeledContent(requestDuplicateText("Requested by"), value: request.authorAlias ?? requestDuplicateText("Alias unavailable"))
            VStack(alignment: .leading, spacing: 4) {
                Text(requestDuplicateText("Original request")).font(.caption).foregroundStyle(.secondary)
                Text(request.originalItem).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(requestDuplicateText("Amount and use, as written")).font(.caption).foregroundStyle(.secondary)
                Text(request.ownQuantity ?? requestDuplicateText("No amount or use supplied"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent(requestDuplicateText("Destination"), value: destination)
            LabeledContent(requestDuplicateText("Request revision"), value: request.revision.formatted())
            LabeledContent(requestDuplicateText("Received"), value: householdTime(request.receivedAt))
            LabeledContent(requestDuplicateText("This request's outcome"), value: shopperRequestStatus(request))
            if let clarification = request.clarification {
                VStack(alignment: .leading, spacing: 4) {
                    Text(requestDuplicateText("Clarification for this requester")).font(.caption).foregroundStyle(.secondary)
                    Text(clarification).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("household.duplicates.request.\(request.id)")
    }
    private var destination: String {
        switch request.route {
        case "current": return requestDuplicateText("This shop")
        case "next": return requestDuplicateText("Next shop")
        default: return requestDuplicateText("Destination unavailable")
        }
    }
}

private func requestDuplicateText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "RequestDuplicates")
}
