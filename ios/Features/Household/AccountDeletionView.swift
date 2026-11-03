import SwiftUI
import HouseholdClient

struct AccountDeletionView: View {
    @ObservedObject var account: HouseholdModel
    @ObservedObject var deletion: AccountDeletionModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var removing: DeletionReceipt?

    private var subject: String? {
        guard !account.locked, account.projection?.grantId == nil else { return nil }
        return account.identity?.subject
    }
    private var visibleReceipts: [DeletionReceipt] {
        guard !account.locked else { return [] }
        return deletion.receipts.filter { account.identity == nil || $0.subject == subject }
    }
    var body: some View {
        Form {
            AccountDeletionScope()
            ForEach(visibleReceipts) { receipt in receiptSection(receipt) }
            if let subject {
                if visibleReceipts.isEmpty || visibleReceipts.allSatisfy({ deletion.missing.contains($0.id) }) {
                    reviewSection(subject)
                }
                if deletion.needsSignIn {
                    Section {
                        if account.emailOTPEnabled {
                            Text(ht("Sign in again with a new email code, then review deletion within five minutes."))
                            Button(ht("Sign out to verify again")) {
                                Task { await account.signOut(); dismiss() }
                            }
                        } else { Text(ht("Fresh email verification is unavailable on this build. Review deletion again when household sign-in is available.")) }
                    }
                }
            } else {
                Section {
                    Text(account.locked ? ht("Unlock household access to review your account.") :
                            ht("Sign in to your adult account to review deletion. Saved receipts can be checked after sign-out."))
                }
            }
            if let notice = deletion.notice { Section { Text(notice) } }
            if deletion.busy { ProgressView(ht("Checking service…")) }
        }
        .disabled(deletion.busy || account.busy)
        .navigationTitle(ht("Account deletion"))
        .task(id: subject) {
            confirming = false
            deletion.clearReview()
            deletion.readReceipts()
            if let subject, visibleReceipts.isEmpty { await deletion.review(subject: subject) }
        }
        .alert(ht("Permanently delete this account?"), isPresented: $confirming) {
            Button(ht("Cancel"), role: .cancel) {}
            Button(ht("Request permanent deletion"), role: .destructive) {
                guard let subject else { return }
                Task { await account.submitAccountDeletion(subject: subject) }
            }
        } message: { Text(ht("You cannot undo an accepted request. The service will apply the household choices you reviewed.")) }
        .alert(ht("Remove this receipt from this phone?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { receipt in
            Button(ht("Cancel"), role: .cancel) {}
            Button(ht("Remove receipt"), role: .destructive) { deletion.forget(receipt) }
        } message: { _ in Text(ht("Removing this receipt ends your ability to check this request on this phone. It does not cancel deletion.")) }
    }

    @ViewBuilder private func reviewSection(_ subject: String) -> some View {
        Section(ht("Review this account")) {
            if let email = account.identity?.email { Text(email) }
            Button(ht("Review current responsibilities")) { Task { await deletion.review(subject: subject) } }
            if let preview = deletion.preview {
                if let days = preview.verifiedBackupRetentionDays {
                    if days == 1 { Text(ht("Older backups may retain data for up to one day.")) }
                    else { Text(String.localizedStringWithFormat(ht("Older backups may retain data for up to %lld days."), Int64(days))) }
                } else { Text(ht("The service has not supplied a verified backup retention period.")) }
                if !preview.adult { Text(ht("This deletion flow is available to adult accounts only.")) }
                else if !preview.deletionAvailable { Text(ht("Account deletion is currently unavailable. Check again later.")) }
                else if !preview.reauthenticationRequired {
                    ForEach(preview.households, id: \.householdId) { household in
                        HouseholdResponsibilities(household: household, choices: $deletion.choices, eraseChildren: true)
                    }
                    Button(ht("Delete my account…"), role: .destructive) { confirming = true }
                        .disabled(!deletion.canSubmit(subject: subject))
                }
            }
        }
    }

    @ViewBuilder private func receiptSection(_ receipt: DeletionReceipt) -> some View {
        Section(ht("Deletion receipt")) {
            Text(receipt.created.formatted(date: .abbreviated, time: .shortened))
            if let status = deletion.statuses[receipt.id] {
                if status.status == .complete {
                    Text(ht("Deletion complete. The service erased the live account data and confirmed deletion of the sign-in account."))
                    if let expiry = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(status.receiptExpiresAt) {
                        Text(String.localizedStringWithFormat(ht("Receipt available until %@."), expiry.formatted(date: .abbreviated, time: .shortened)))
                    }
                } else {
                    Text(ht("Deletion accepted and still pending. Check this receipt again later."))
                    if status.appDataErased { Text(ht("Live application data has been erased.")) }
                }
            } else { Text(ht("This device saved a receipt. Check it to learn whether the service accepted the request.")) }
            Button(ht("Check deletion status")) {
                Task { if await deletion.check(receipt) { await account.deletionAccepted(subject: receipt.subject) } }
            }
            if deletion.statuses[receipt.id]?.status == .complete || deletion.missing.contains(receipt.id) {
                Button(ht("Remove receipt from this phone"), role: .destructive) { removing = receipt }
            }
        }
    }
}

struct AccountDeletionScope: View {
    var body: some View {
        Section(ht("What will be deleted")) {
            Text(ht("This permanently deletes your household service account and its private data across all households. Access ends when the service accepts the request. The receipt shows when deletion finishes."))
            Text(ht("Leaving one household only ends that membership. Account deletion applies to every household."))
            Text(ht("Your private Records stay on this phone. Copies you already shared stay with their recipients. Other members keep their own records."))
            Text(ht("An App Store subscription can continue to renew after account deletion."))
            Link(ht("Manage App Store subscriptions"), destination: URL(string: "https://apps.apple.com/account/subscriptions/")!)
        }
    }
}

struct HouseholdResponsibilities: View {
    let household: DeletionPreview.Household
    @Binding var choices: DeletionChoices
    let eraseChildren: Bool
    @ViewBuilder var body: some View {
        Text(household.label).font(.headline)
        if household.needsOrganizer {
            choice(ht("Organizer responsibility"), fallback: ht("Archive if I am the last organizer"),
                   adults: household.otherAdults, selection: $choices.organizers[household.householdId])
        }
        ForEach(household.activeShops, id: \.shopId) { shop in
            choice(String.localizedStringWithFormat(ht("Shop %@ · %@"), String(shop.shopId.prefix(8)), phase(shop.phase)), fallback: ht("Close the app’s shop"),
                   adults: household.otherAdults, selection: $choices.shops[.init(household: household.householdId, id: shop.shopId)])
        }
        if !household.activeShops.isEmpty { Text(ht("Closing a shop here does not cancel a retailer order.")) }
        if eraseChildren {
            ForEach(household.soleGuardianChildren, id: \.memberId) { child in
                let target = DeletionChoices.Target(household: household.householdId, id: child.memberId)
                Toggle(String.localizedStringWithFormat(ht("Erase %@’s child profile in this household"), child.alias),
                       isOn: Binding(get: { choices.children.contains(target) }, set: {
                    if $0 { choices.children.insert(target) } else { choices.children.remove(target) }
                }))
            }
            if !household.soleGuardianChildren.isEmpty { Text(ht("This affects only the listed household profiles where you are the sole verified guardian.")) }
        }
    }

    private func phase(_ value: String) -> String {
        switch value {
        case "draft": ht("Draft shared shop")
        case "frozen": ht("Frozen shared shop")
        case "placed": ht("Order reported placed")
        default: ht("Check current shop status")
        }
    }

    private func choice(_ label: String, fallback: String, adults: [DeletionPreview.Adult],
                        selection: Binding<DeletionChoices.Responsibility?>) -> some View {
        Picker(label, selection: selection) {
            Text(ht("Choose an action")).tag(nil as DeletionChoices.Responsibility?)
            Text(fallback).tag(Optional(DeletionChoices.Responsibility.archiveOrClose))
            ForEach(adults, id: \.memberId) { adult in
                Text(String.localizedStringWithFormat(ht("Transfer to %@"), adult.alias)).tag(Optional(DeletionChoices.Responsibility.transfer(adult.memberId)))
            }
        }
    }

}
