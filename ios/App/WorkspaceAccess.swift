import SwiftUI
import LocalAuthentication

/// Once a shared persona has used this installation, returning to local adult
/// records requires device-owner authentication, including after sign-out/relaunch.
@MainActor final class WorkspaceAccess: ObservableObject {
    @Published private(set) var unlocked: Bool
    @Published private(set) var checking = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    let localActorID: UUID
    private let key = "protectedLocalWorkspace"
    private(set) var generation = UUID()
    private var authentication: LAContext?
    var isProtected: Bool { defaults.bool(forKey: key) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: "installationPlannerID"), let id = UUID(uuidString: stored) {
            localActorID = id
        } else {
            let id = UUID()
            localActorID = id
            defaults.set(id.uuidString, forKey: "installationPlannerID")
        }
        unlocked = !defaults.bool(forKey: key)
    }
    func protect() { defaults.set(true, forKey: key); generation = UUID(); authentication?.invalidate(); unlocked = false }
    func background() { generation = UUID(); authentication?.invalidate(); if isProtected { unlocked = false } }
    func unlock() async {
        guard !checking else { return }
        checking = true
        error = nil
        defer { checking = false; authentication = nil }
        let context = LAContext()
        authentication = context
        let attempt = generation
        var reason: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &reason) else {
            error = tr("Set an iPhone passcode to protect and reopen your private workspace.")
            return
        }
        do {
            let allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: tr("Open your private shopping workspace"))
            guard generation == attempt else { return }
            unlocked = allowed
            if unlocked { error = nil }
        } catch { guard generation == attempt else { return }; self.error = tr("Your private workspace is still locked. You can try again.") }
    }
}

struct HouseholdWorkspaceProtection: ViewModifier {
    @ObservedObject var household: HouseholdModel
    let access: WorkspaceAccess
    func body(content: Content) -> some View {
        content
            .onChange(of: household.identity?.subject) { _, subject in if subject != nil { access.protect() } }
            .onChange(of: household.projection?.memberId) { _, id in if id != nil { access.protect() } }
    }
}

struct WorkspaceUnlockView: View {
    @ObservedObject var access: WorkspaceAccess
    @ObservedObject var household: HouseholdModel
    var childExitNotice: String? = nil
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label {
                        Text(tr("Private workspace")).font(.largeTitle.bold())
                    } icon: {
                        Image(systemName: "lock.fill").font(.title2).foregroundStyle(Theme.action)
                    }
                    .accessibilityAddTraits(.isHeader)
                    if let childExitNotice {
                        Text(childExitNotice)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("guardian.childExitNotice")
                    }
                    Text(tr("Unlock to return to your saved groceries, meals and costs."))
                        .foregroundStyle(Theme.secondary)

                    Button {
                        Task { await access.unlock() }
                    } label: {
                        HStack(spacing: 8) {
                            if access.checking { ProgressView().accessibilityHidden(true) }
                            Text(tr("Unlock private workspace"))
                        }
                    }
                    .buttonStyle(PrimaryAction()).disabled(access.checking)
                    if let error = access.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Theme.error)
                            .accessibilityFocused($errorFocused)
                    }
                    NavigationLink {
                        HouseholdSettingsView(model: household)
                    } label: {
                        Label(tr("Household requests"), systemImage: "person.2")
                            .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .workingSurface()
            .onChange(of: access.error) { _, error in errorFocused = error != nil }
            .navigationDestination(isPresented: Binding(
                get: { household.showingVerifiedHousehold },
                set: { if !$0 { household.dismissVerifiedHousehold() } }
            )) { HouseholdSettingsView(model: household) }
        }
    }
}
