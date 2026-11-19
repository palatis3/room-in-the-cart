import SwiftUI
import HouseholdClient

struct SharedMessageField: Hashable {
    let source: SharedMessageSource
    let wording: String
    init?(_ kind: SharedMessageSource.Kind, _ id: String, _ revision: Int, _ field: SharedMessageSource.Field, _ wording: String?, index: Int? = nil) {
        guard let wording, !wording.isEmpty, let source = SharedMessageSource(kind: kind, id: id, revision: revision, field: field, index: index) else { return nil }
        self.source = source
        self.wording = wording
    }

    static func request(_ row: OwnRequest) -> [Self] {
        [Self(.request, row.id, row.revision, .item, row.originalItem),
         Self(.request, row.id, row.revision, .amount, row.ownQuantity)].compactMap { $0 }
    }
    static func instruction(_ view: HelperView) -> [Self] {
        var fields = [Self(.instruction, view.grantId, view.revision, .shopLabel, view.shopLabel)].compactMap { $0 }
        for (index, item) in view.items.enumerated() {
            fields += [(SharedMessageSource.Field.label, Optional(item.label)), (.amount, item.amount), (.unit, item.unit), (.action, item.action)].compactMap {
                Self(.instruction, view.grantId, view.revision, $0.0, $0.1, index: index)
            }
        }
        return fields
    }
    static func cookCopy(_ copy: SharedCookCopy) -> [Self] {
        // A long dated note can be reported without disclosing its other lines.
        var excerpts: [Self] = []
        for line in copy.text.split(whereSeparator: { $0.isNewline }) {
            var excerpt = ""
            for scalar in line.unicodeScalars {
                if excerpt.utf8.count + scalar.utf8.count > 1000 {
                    if let field = Self(.cookCopy, copy.id.uuidString, copy.version, .text, excerpt) { excerpts.append(field) }
                    excerpt = ""
                }
                excerpt.unicodeScalars.append(scalar)
            }
            if let field = Self(.cookCopy, copy.id.uuidString, copy.version, .text, excerpt) { excerpts.append(field) }
        }
        return excerpts
    }
}

/// Keeps an exact uncertain action while navigating the same enrolled session.
@MainActor final class SharedSafetyReviews {
    private var entries: [SharedMessageSource: SharedSafetyReview] = [:]
    func review(for source: SharedMessageSource) -> SharedSafetyReview {
        if let previous = entries[source] { return previous }
        let review = SharedSafetyReview()
        entries[source] = review
        return review
    }
    func clear() { entries.removeAll() }
}

@MainActor struct SharedSafetyChannel {
    let reviews: SharedSafetyReviews
    let generation: UUID
    let scoped: () -> Bool
    let send: (SharedContentAction) async throws -> SharedContentReceipt
    let refreshAfterBlock: () async -> Void

    init?(reviews: SharedSafetyReviews, generation: UUID, scope: HouseholdBootstrap?, service: HouseholdService?, current: @escaping () -> Bool,
          afterBlock: @escaping () async -> Void) {
        guard let scope, scope.supportsSharedContentSafety, let service else { return nil }
        self.reviews = reviews
        self.generation = generation
        scoped = current
        send = { action in
            guard current() else { throw ClientError.cancelled }
            return try await service.submitSharedContentAction(action, reviewed: scope)
        }
        refreshAfterBlock = { if current() { await afterBlock() } }
    }

    init(generation: UUID, scoped: @escaping () -> Bool,
         send: @escaping (SharedContentAction) async throws -> SharedContentReceipt,
         refreshAfterBlock: @escaping () async -> Void) {
        reviews = SharedSafetyReviews()
        self.generation = generation
        self.scoped = scoped
        self.send = send
        self.refreshAfterBlock = refreshAfterBlock
    }
}

@MainActor final class SharedSafetyReview: ObservableObject, Identifiable {
    enum Status { case ready, sending, retry, reported, blocked, stale, unavailable, unattributed }
    @Published private(set) var status = Status.ready
    private(set) var pending: SharedContentAction?

    func submit(_ action: SharedContentAction, through channel: SharedSafetyChannel) async {
        guard channel.scoped(), (status == .ready && pending == nil) || (status == .retry && pending == action) else { return }
        pending = action
        status = .sending
        do {
            let receipt = try await channel.send(action)
            guard channel.scoped() else { pending = nil; status = .unavailable; return }
            guard receipt.status == (action.action == .block ? .blocked : .received) else { throw ClientError.invalidResponse }
            pending = nil
            status = action.action == .block ? .blocked : .reported
        } catch {
            guard channel.scoped() else { pending = nil; status = .unavailable; return }
            switch error as? ClientError {
            case .service(409, "sender_unavailable", _, _): status = .unattributed
            case .service(409, _, _, _), .service(404, _, _, _): status = .stale
            case .sessionNeeded, .accessEnded, .service(503, "moderation_unavailable", _, _): status = .unavailable
            default: status = .retry; return
            }
            pending = nil
        }
    }
}

struct SharedSafetyButton: View {
    let channel: SharedSafetyChannel?
    let fields: [SharedMessageField]
    var body: some View {
        if let channel, let first = fields.first, channel.scoped() {
            SharedSafetyPresentation(channel: channel, fields: fields)
                .id(Identity(generation: channel.generation, source: first.source))
        }
    }
    private struct Identity: Hashable { let generation: UUID; let source: SharedMessageSource }
}

private struct SharedSafetyPresentation: View {
    let channel: SharedSafetyChannel
    let fields: [SharedMessageField]
    @State private var selectedReview: SharedSafetyReview?
    var body: some View {
        Button(ht("Report or block")) {
            if let first = fields.first { selectedReview = channel.reviews.review(for: first.source) }
        }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("safety.open")
            .sheet(item: $selectedReview) { review in
                NavigationStack {
                    SharedSafetyEditor(channel: channel, fields: fields, review: review)
                }
            }
    }
}

private struct SharedSafetyEditor: View {
    let channel: SharedSafetyChannel
    let fields: [SharedMessageField]
    @ObservedObject var review: SharedSafetyReview
    @State private var action = SharedContentAction.Action.report
    @State private var reason: SharedContentAction.Reason?
    @State private var include = false
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        WorkingForm {
            if channel.scoped() {
                switch review.status {
                case .ready:
                    Picker(ht("Action"), selection: $action) {
                        Text(ht("Report privately")).tag(SharedContentAction.Action.report)
                        Text(ht("Block sender")).tag(SharedContentAction.Action.block)
                    }.accessibilityIdentifier("safety.action")
                    if action == .report {
                        Picker(ht("Reason for reporting"), selection: $reason) {
                            Text(ht("Choose a reason")).tag(SharedContentAction.Reason?.none)
                            ForEach(SharedContentAction.Reason.allCases, id: \.self) { choice in
                                Text(sharedSafetyReason(choice)).tag(Optional(choice))
                            }
                        }.accessibilityIdentifier("safety.reason")
                        Text(ht("Your report goes to the safety team with the reason and a reference to this message."))
                        Toggle(ht("Include an excerpt"), isOn: $include)
                        if include {
                            if fields.count > 1 {
                                Picker(ht("Choose the excerpt"), selection: $selected) {
                                    ForEach(fields.indices, id: \.self) { i in Text(verbatim: fields[i].wording).tag(i) }
                                }
                            }
                            if fields.indices.contains(selected) {
                                Section(ht("Exact excerpt to send")) { Text(verbatim: fields[selected].wording).accessibilityIdentifier("safety.excerpt") }
                            }
                        }
                    } else {
                        Text(ht("Block this sender’s shared messages from your view. The block sends a message reference without an excerpt."))
                    }
                    if fields.indices.contains(selected) {
                        let source = fields[selected]
                        Button(action == .report ? ht("Send private report") : ht("Confirm block")) {
                            let submission: SharedContentAction
                            if action == .report {
                                guard let reason else { return }
                                submission = .report(source: source.source, reason: reason, excerpt: include ? source.wording : nil)
                            } else {
                                submission = .block(source: source.source)
                            }
                            Task { await review.submit(submission, through: channel) }
                        }.disabled(action == .report && reason == nil).accessibilityIdentifier("safety.confirm")
                    }
                case .sending: ProgressView(ht("Sending…"))
                case .retry:
                    Text(ht("Delivery is unconfirmed. Retry the same action to check its result."))
                    if let pending = review.pending {
                        LabeledContent(ht("Action"), value: pending.action == .report ? ht("Report privately") : ht("Block sender"))
                        if let reason = pending.reason {
                            LabeledContent(ht("Reason for reporting"), value: sharedSafetyReason(reason))
                        }
                        if let text = pending.text { Section(ht("Exact excerpt to send")) { Text(verbatim: text) } }
                        Button(ht("Retry the same action")) { Task { await review.submit(pending, through: channel) } }
                    }
                case .reported:
                    Text(ht("Your private report was received."))
                    Button(ht("Block sender")) { review.chooseAnotherAction(); action = .block; include = false }
                case .blocked: Text(ht("Sender blocked."))
                case .stale: Text(ht("This message changed or is no longer available. Refresh before reviewing it again."))
                case .unavailable: Text(ht("This action is unavailable for the current household access."))
                case .unattributed:
                    Text(ht("The sender of this message could not be verified for blocking."))
                    Button(ht("Report privately")) { review.chooseAnotherAction(); action = .report; include = false }
                }
            } else { Text(ht("This action is unavailable for the current household access.")) }
        }
        .navigationTitle(ht("Report or block"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(ht("Close")) { dismiss() }.disabled(review.status == .sending)
            }
        }
        .interactiveDismissDisabled(review.status == .sending)
        .onDisappear { if review.status == .blocked { Task { await channel.refreshAfterBlock() } } }
    }
}

private extension SharedSafetyReview {
    func chooseAnotherAction() { if status == .reported || status == .unattributed { status = .ready } }
}

private func sharedSafetyReason(_ reason: SharedContentAction.Reason) -> String {
    switch reason {
    case .harassment: return ht("Harassment")
    case .unsafe: return ht("Unsafe content")
    case .other: return ht("Another reason")
    }
}

func sharedPublicationNotice(_ error: Error) -> String? {
    switch error as? ClientError {
    case .service(422, "content_review_required", _, _):
        return ht("This wording could not be shared. Edit it and review it again before sending.")
    case .service(403, "shared_posting_unavailable", _, _):
        return ht("Posting shared messages is unavailable for this account. You can still read messages and use the safety controls.")
    default: return nil
    }
}
