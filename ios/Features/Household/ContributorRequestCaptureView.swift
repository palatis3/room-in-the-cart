import SwiftUI

/// Capture returns one reviewed own-request payload. It has no basket mutation port.
@MainActor struct ContributorRequestCaptureView: View {
    @ObservedObject var household: HouseholdModel
    let scope: ContributorRequestScope
    let capture: Bool
    @State private var review: ContributorRequestReview?
    @State private var approved = false
    @State private var failure: String?
    @State private var sending = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.locale) private var locale

    private var authorized: Bool { !sending && household.contributorRequestScope == scope }
    private var captureLanguage: String { locale.language.languageCode?.identifier == "es" ? "es-US" : "en-US" }
    var body: some View {
        Group {
            if let review {
                Form {
                    Section(ht("Original wording")) { Text(review.originalText).textSelection(.enabled) }
                    Section(ht("Request the household will receive")) {
                        LabeledContent(ht("Item"), value: review.item)
                        LabeledContent(ht("Quantity"), value: review.quantity.isEmpty ? ht("Unknown amount") : review.quantity)
                        LabeledContent(ht("Destination"), value: scope.destination)
                        if scope.editing != nil { Text(ht("This edits only your selected request.")) }
                        if scope.followingUp != nil { Text(ht("This follow-up leaves the accepted request unchanged.")) }
                        Text(ht("Only the shopper can change the basket. Sending a request does not buy an item or confirm its price."))
                    }
                    Section {
                        Toggle(ht("I reviewed the original wording, item, quantity, packs, exclusions and destination."), isOn: $approved)
                            .accessibilityIdentifier("household.request.approve")
                        Button(ht("Send reviewed request")) { Task {
                            guard authorized, approved else { return }
                            sending = true
                            await household.sendRequest(reviewed: review, approved: true)
                            sending = false
                            // Once persisted, the original exact retry belongs to the household screen.
                            // A failure before persistence keeps this reviewed text available here.
                            switch household.delivery {
                            case .waiting, .received, .needsReview: dismiss()
                            default: approved = false; failure = household.notice
                            }
                        } }.disabled(!authorized || !approved).accessibilityIdentifier("household.request.sendReviewed")
                        if let failure { Text(failure).accessibilityIdentifier("household.request.reviewError") }
                        Text(ht("Cancelling leaves your request unsent. No captured photo or audio is sent with this request."))
                    }
                }.navigationTitle(ht("Review your request"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
            } else if capture {
                CaptureReviewView(initialText: scope.quantity.isEmpty ? scope.item : scope.quantity + " " + scope.item,
                    localeIdentifier: captureLanguage, destination: scope.destination, requestMode: true, dismissOnReview: false,
                    correctionScope: household.contributorCorrectionScope(for: scope, localeIdentifier: CaptureCorrectionScope.appLanguage()),
                    authorize: { authorized }) { value in
                        guard authorized else { return }
                        do { review = try ContributorRequestReview.captured(value, scope: scope); approved = false }
                        catch { failure = message(error) }
                    }
            } else {
                Form { if let failure { Text(failure) } }
                    .navigationTitle(ht("Review your request"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
            }
        }
        .task {
            if !capture { do { review = try ContributorRequestReview.typed(scope: scope) } catch { failure = message(error) } }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if !sending && !authorized { review = nil; approved = false; dismiss(); return }
            }
        }
        .onChange(of: phase) { _, value in if value == .background { review = nil; approved = false; dismiss() } }
        .alert(ht("Review needed"), isPresented: Binding(get: { capture && failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(ht("Cancel")) { dismiss() }
        } message: { Text(failure ?? "") }
    }
    private func message(_ error: Error) -> String {
        switch error {
        case ContributorRequestReviewError.oneItem:
            return ht("Keep exactly one reviewed item for this request. Skip other lines or cancel; nothing has been sent.")
        case ContributorRequestReviewError.destination:
            return ht("Confirm the displayed request destination. Nothing has been sent.")
        default:
            return ht("The complete request, including original wording, purpose and exclusions, must fit 240 item characters and 80 quantity characters. Shorten the source request and review again; nothing was truncated or sent.")
        }
    }
}
