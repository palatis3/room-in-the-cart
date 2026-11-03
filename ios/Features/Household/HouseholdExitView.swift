import SwiftUI
import HouseholdClient

struct HouseholdExitView: View {
    @ObservedObject var account: HouseholdModel
    @ObservedObject var exit: HouseholdExitModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    private var subject: String? {
        guard !account.locked, account.projection?.grantId == nil else { return nil }
        return account.identity?.subject
    }
    var body: some View {
        Form {
            Section {
                Text(ht("Leaving ends your access to one household and its shared views. You keep your account, other memberships and private Records. Your App Store subscription is managed separately."))
            }
            if let subject {
                if let pending = exit.pending {
                    Section(ht("Saved exit request")) {
                        Text(pending.householdLabel)
                        Button(ht("Retry the saved exit request")) { Task { await finish(await exit.send(subject: subject)) } }
                    }
                } else {
                    Section(ht("Your households")) {
                        Button(ht("Review current memberships")) { Task { await exit.review(subject: subject) } }
                        if let preview = exit.preview {
                            if !preview.adult { Text(ht("Only an adult account can leave a household here.")) }
                            else {
                                let active = preview.households.filter { $0.state == "active" }
                                if active.isEmpty { Text(ht("This account has no active household memberships.")) }
                                ForEach(active, id: \.householdId) { household in
                                    Button(household.label) { exit.select(household) }.disabled(preview.reauthenticationRequired)
                                }
                            }
                        }
                    }
                    if let selected = exit.selected {
                        Section(ht("Review household exit")) {
                            HouseholdResponsibilities(household: selected, choices: $exit.choices, eraseChildren: false)
                            if !selected.soleGuardianChildren.isEmpty {
                                Text(ht("Resolve sole guardianship before leaving. Leaving a household cannot erase a child profile."))
                                if account.projection?.household.id == selected.householdId, let lifecycle = account.lifecycle, !lifecycle.isHelper {
                                    NavigationLink(ht("Guardian controls")) { HouseholdGuardianView(model: lifecycle) }
                                }
                            }
                            Button(ht("Leave this household…"), role: .destructive) { confirming = true }.disabled(!exit.canLeave)
                        }
                    }
                }
                if exit.needsSignIn {
                    if account.emailOTPEnabled {
                        Text(ht("Sign in again with a new email code before leaving a household."))
                        Button(ht("Sign out to verify again")) { Task { await account.signOut(); dismiss() } }
                    } else { Text(ht("Fresh email verification is unavailable on this build.")) }
                }
            } else { Text(ht("Sign in to your adult account to review household memberships.")) }
            if let notice = exit.notice { Section { Text(notice) } }
            if exit.busy { ProgressView(ht("Checking service…")) }
        }
        .disabled(exit.busy || account.busy)
        .navigationTitle(ht("Leave a household"))
        .task(id: subject) {
            confirming = false
            if let subject { await exit.review(subject: subject) } else { exit.clear() }
        }
        .alert(ht("Leave this household?"), isPresented: $confirming) {
            Button(ht("Cancel"), role: .cancel) {}
            Button(ht("Confirm household exit"), role: .destructive) {
                if let subject { Task { await finish(await exit.confirm(subject: subject)) } }
            }
        } message: { if let selected = exit.selected { Text(String.localizedStringWithFormat(ht("Your membership in %@ will end and the reviewed choices will apply."), selected.label)) } }
    }
    private func finish(_ intent: HouseholdExitIntent?) async {
        if let intent { await account.householdExited(intent) }
        else if let pending = exit.pending { await account.hideExitingScope(pending) }
    }
}
