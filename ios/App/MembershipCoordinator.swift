import Foundation
import Combine

/// A projection of the authenticated, enrolled adult scope. It contains no credentials.
struct MembershipSession: Equatable, Sendable {
    let subjectID: String
    let memberID: String
    let accountName: String
    let householdID: String
    let householdName: String
    let serviceURL: URL
}

enum MembershipSessionEvent: Equatable { case projection, identity, lock }

@MainActor protocol MembershipSessionSource: AnyObject {
    var membershipSession: MembershipSession? { get }
    var membershipSessionChanges: AnyPublisher<MembershipSessionEvent, Never> { get }
    var onScopeChange: (() -> Void)? { get set }
    func refreshMembershipAuthorization() async
    func membershipAccessToken() async throws -> String
    func membershipDeviceToken() async throws -> String
}

@MainActor struct MembershipCredentials {
    let accessToken: () async throws -> String
    let deviceToken: () async throws -> String
}

/// App-owned lifecycle, independent of whether a membership screen is visible.
@MainActor final class MembershipCoordinator: ObservableObject {
    typealias Factory = @MainActor (MembershipSession, MembershipCredentials) async throws -> MembershipModel
    @Published private(set) var model: MembershipModel?
    @Published private(set) var isLoading = false
    @Published private(set) var failure = false
    private weak var source: (any MembershipSessionSource)?
    private var changes: AnyCancellable?
    private var modelChanges: AnyCancellable?
    private var activeSession: MembershipSession?
    private var loadingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var sourceRevision = 0
    private var awaitingProjection = false
    private let factory: Factory

    init(factory: Factory? = nil) { self.factory = factory ?? Self.makeModel }
    deinit { loadingTask?.cancel(); refreshTask?.cancel() }

    /// Call once from the app root. Repeated binding to the same source is harmless.
    func bind(to source: any MembershipSessionSource) {
        guard self.source !== source else { return }
        stop()
        changes?.cancel()
        self.source = source
        awaitingProjection = false
        let previous = source.onScopeChange
        source.onScopeChange = { [weak self, weak source] in
            if let self, let source, self.source === source { self.stop() }
            previous?()
        }
        changes = source.membershipSessionChanges.sink { [weak self, weak source] event in
            guard let self, let source else { return }
            self.schedule(event, from: source)
        }
        schedule(.projection, from: source)
    }

    /// Synchronous invalidation runs before lock, sign-out or new device enrollment starts.
    /// Reactivation then requires a newly published authorized projection.
    func stop() {
        sourceRevision += 1
        awaitingProjection = true
        clearActive()
    }

    /// Call when the scene becomes active. Never prompts AppStore.sync().
    func foreground() {
        guard !awaitingProjection, let source, let session = source.membershipSession else { return }
        if let activeSession, activeSession != session { stop(); return }
        if model == nil {
            activate(session, from: source)
            return
        }
        guard !isLoading, refreshTask == nil, let model else { return }
        let current = generation
        refreshTask = Task { [weak self, weak model] in
            guard let model else { return }
            await model.refresh()
            guard let self, self.generation == current else { return }
            self.refreshTask = nil
        }
    }

    func retry() async {
        guard let source, let session = source.membershipSession else { return }
        if awaitingProjection {
            // A rejected credential requires a new server-verified household projection.
            // Its publisher will reactivate membership only if this adult still has access.
            if failure { await source.refreshMembershipAuthorization() }
            return
        }
        if model != nil { foreground() }
        else { activate(session, from: source) }
    }

    private func schedule(_ event: MembershipSessionEvent, from source: any MembershipSessionSource) {
        let revision = sourceRevision
        // @Published emits before its stored value changes. Read the complete source on the next actor turn.
        Task { [weak self, weak source] in
            guard let self, let source, self.source === source, self.sourceRevision == revision else { return }
            guard let session = source.membershipSession else { self.stop(); return }
            if self.awaitingProjection && event != .projection { return }
            if event == .identity, let active = self.activeSession, active.subjectID != session.subjectID {
                self.stop(); return
            }
            self.awaitingProjection = false
            self.activate(session, from: source)
        }
    }

    private func clearActive() {
        generation += 1
        loadingTask?.cancel(); loadingTask = nil
        refreshTask?.cancel(); refreshTask = nil
        modelChanges?.cancel(); modelChanges = nil
        model?.stop(); model = nil
        activeSession = nil
        isLoading = false
        failure = false
    }

    private func activate(_ session: MembershipSession, from source: any MembershipSessionSource) {
        guard self.source === source, source.membershipSession == session else { return }
        if activeSession == session && (model != nil || isLoading) { return }
        clearActive()
        activeSession = session
        isLoading = true
        let current = generation
        let credentials = MembershipCredentials(
            accessToken: { [weak self, weak source] in
                guard let self, let source, self.generation == current, source.membershipSession == session else { throw MembershipFailure.signInRequired }
                let token = try await source.membershipAccessToken()
                guard self.generation == current, source.membershipSession == session else { throw MembershipFailure.signInRequired }
                return token
            },
            deviceToken: { [weak self, weak source] in
                guard let self, let source, self.generation == current, source.membershipSession == session else { throw MembershipFailure.signInRequired }
                let token = try await source.membershipDeviceToken()
                guard self.generation == current, source.membershipSession == session else { throw MembershipFailure.signInRequired }
                return token
            })
        let factory = self.factory
        loadingTask = Task { [weak self] in
            do {
                let fresh = try await factory(session, credentials)
                guard let self, self.generation == current, !Task.isCancelled else { fresh.stop(); return }
                self.model = fresh
                self.modelChanges = fresh.$state.sink { [weak self] state in
                    guard let self, self.generation == current else { return }
                    self.objectWillChange.send()
                    guard state.issue == .signInRequired else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current else { return }
                        self.stop()
                        self.failure = true
                    }
                }
                await fresh.start()
                guard self.generation == current else { return }
                self.isLoading = false
                self.loadingTask = nil
            } catch {
                guard let self, self.generation == current else { return }
                if error as? MembershipFailure == .signInRequired { self.stop() }
                self.isLoading = false
                self.failure = true
                self.loadingTask = nil
            }
        }
    }

    private static func makeModel(session: MembershipSession, credentials: MembershipCredentials) async throws -> MembershipModel {
        let service = try HTTPMembershipEntitlementService(baseURL: session.serviceURL,
            deviceToken: credentials.deviceToken, token: credentials.accessToken)
        let token: UUID?
        do { token = try await service.purchaseContext(householdID: session.householdID) }
        catch MembershipFailure.notPurchaser { token = nil }
        let context = MembershipContext(purchaserID: session.memberID, purchaserName: session.accountName,
            householdID: session.householdID, householdName: session.householdName, appAccountToken: token)
        return MembershipModel(context: context, service: service)
    }
}
