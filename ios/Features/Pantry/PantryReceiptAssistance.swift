import CoreDomain
import HouseholdClient
import SwiftUI

/// Accepting a suggestion only edits the existing row. It never selects an acquisition action or confirms usable stock.
extension ReceiptImportDraft.Line {
    mutating func applyAssisted(_ suggestion: ReceiptLineSuggestion, request: ReceiptLineAssistanceRequest,
                                reviewedLine: Self, useReceived: Bool) throws {
        try suggestion.validate(for: request)
        guard self == reviewedLine, request.page == (documentLine?.page ?? 1),
              request.line == (documentLine?.line ?? ordinal + 1) else { throw PantryReceiptError.stale }
        var amount: (String, UnitOfMeasure)?
        if useReceived {
            guard let number = suggestion.quantity, let code = suggestion.unit, let measured = UnitOfMeasure(rawValue: code),
                  let validated = try ComparisonModel.quantity(number, measured), validated.amount > .zero else {
                throw PantryReceiptError.invalid
            }
            amount = (number, measured)
        }
        if let name = suggestion.foodName { clearAlias(); self.name = name }
        if let (number, unit) = amount {
            // A unit applies to both fields. Require the shopper to enter usable stock again when units change.
            if self.unit != unit { usable = "" }
            self.unit = unit
            received = number
        }
    }
}

@MainActor struct PantryReceiptAssistance: View {
    let line: ReceiptImportDraft.Line
    let authorized: () -> Bool
    let checkSource: () async throws -> Void
    let apply: (ReceiptLineSuggestion, ReceiptLineAssistanceRequest, Bool) throws -> Void
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var basis: CapturePrivateIdentity?
    @State private var checked = false
    @State private var available = false
    @State private var sending = false
    @State private var request: ReceiptLineAssistanceRequest?
    @State private var attempts = 0
    @State private var result: ReceiptLineSuggestion?
    @State private var received = false
    @State private var feedback: String?
    @State private var task: Task<Void,Never>?
    @State private var operation = UUID()

    private var identity: CapturePrivateIdentity? {
        guard scene == .active, authorized(), !household.guardianChildOnly,
              household.projection?.grantId == nil else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var current: Bool { basis?.subject != nil && identity == basis }
    private var serviceScope: ReceiptAssistanceScope? {
        guard let identified = identity, let subject = identified.subject, let householdID = identified.householdID,
              let memberID = identified.memberID else { return nil }
        return .init(subject: subject, householdID: householdID, memberID: memberID, shopID: household.projection?.shopId)
    }
    var body: some View {
        NavigationStack {
            Form {
                if identity != nil { Section(pantryText("Original receipt wording")) { Text(verbatim: line.original) } }
                if !checked { ProgressView() }
                else if !current {
                    Text(pantryText("For optional online help, open an authorized adult account. You can keep editing the receipt here."))
                } else if !available {
                    Text(pantryText("Online receipt help is unavailable. You can keep editing the receipt on this iPhone."))
                } else {
                    Section(pantryText("Text to share with OpenAI")) {
                        Text(pantryText("Edit or remove personal details. Your chosen text and its page and line numbers go to OpenAI through Room in the Cart."))
                        TextField(pantryText("Selected receipt wording"), text: $selected, axis: .vertical)
                            .disabled(sending).accessibilityIdentifier("receipt.assistance.text")
                        Text(pantryFormat("Page %lld · line %lld", Int64(line.documentLine?.page ?? 1), Int64(line.documentLine?.line ?? line.ordinal + 1)))
                        Button(pantryText("Send this text for a suggestion")) { send() }
                            .disabled(!ReceiptLineAssistanceRequest.accepts(selected) || sending || result != nil || attempts >= 2)
                            .accessibilityIdentifier("receipt.assistance.send")
                    }
                    if sending { ProgressView(pantryText("Reading selected wording…")) }
                    if let result, let request {
                        Section(pantryText("Review the suggestion")) {
                            if let name = result.foodName { LabeledContent(pantryText("Suggested food"), value: name) }
                            if let quantity = result.quantity, let unit = result.unit.flatMap(UnitOfMeasure.init(rawValue:)) {
                                LabeledContent(pantryText("Printed quantity"), value: quantity + " " + pantryUnit(unit))
                                Toggle(pantryText("I received this quantity and want to use it."), isOn: $received)
                            }
                            if result.foodName == nil && result.quantity == nil { Text(pantryText("No food or quantity could be identified.")) }
                            else {
                                Button(pantryText("Use in my receipt draft")) {
                                    do {
                                        guard current else { throw PantryReceiptError.stale }
                                        try apply(result, request, received)
                                        dismiss()
                                    } catch { feedback = pantryText("The receipt changed. Reopen the line to review it again.") }
                                }.disabled(result.foodName == nil && !received)
                                .accessibilityIdentifier("receipt.assistance.apply")
                            }
                        }
                    }
                }
                if let feedback { Text(feedback).accessibilityIdentifier("receipt.assistance.status") }
            }
            .navigationTitle(pantryText("Help with this line"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Close")) { cancel(); dismiss() } } }
            .privacySensitive()
        }
        .task {
            selected = String(line.original.prefix(500))
            basis = identity
            guard current, let scope = serviceScope, let service = household.service else { checked = true; return }
            let active = operation
            let offered = (try? await service.receiptAssistanceAvailable(scope: scope)) == true
            if !Task.isCancelled && operation == active && current && serviceScope == scope { available = offered }
            checked = true
        }
        .onChange(of: selected) { _, _ in request = nil; result = nil; received = false; attempts = 0; feedback = nil }
        .onChange(of: identity) { _, next in if basis != nil && next != basis { cancel(); dismiss() } }
        .onDisappear { cancel() }
    }
    private func cancel() {
        operation = UUID(); task?.cancel(); task = nil; sending = false; result = nil; request = nil
    }
    private func send() {
        guard current, available, !sending, attempts < 2, let scope = serviceScope, let service = household.service,
              let input = try? request ?? ReceiptLineAssistanceRequest(consentingTo: selected,
                    page: line.documentLine?.page ?? 1, line: line.documentLine?.line ?? line.ordinal + 1) else { return }
        request = input; attempts += 1; sending = true; feedback = nil
        let active = operation
        task = Task {
            defer { if active == operation { sending = false } }
            do {
                try await checkSource()
                guard !Task.isCancelled, active == operation, current, request == input, serviceScope == scope else { return }
                let proposed = try await service.receiptLineSuggestion(input, scope: scope)
                guard !Task.isCancelled, active == operation, current, request == input, serviceScope == scope else { return }
                result = proposed
            } catch {
                if !Task.isCancelled && active == operation && current {
                    feedback = pantryText("No suggestion was received. Your local receipt is ready to edit.")
                }
            }
        }
    }
}
