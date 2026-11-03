import Foundation

/// A service grant never follows from account login alone. Enrollment is an explicit UI action.
public actor HouseholdService {
    private let configuration: ServiceConfiguration
    private let transport: HTTPTransport
    private let auth: AdultAuth
    private let deviceVault: any RefreshTokenVault
    private var enrollment: DeviceEnrollment?
    private var householdID: String?
    private var subject: String?
    private var memberID: String?
    private var selectedShopID: UUID?
    private var selectedGrantID: String?
    private var generation = UUID()
    public init(configuration: ServiceConfiguration, auth: AdultAuth, deviceVault: any RefreshTokenVault,
                transport: HTTPTransport = .init()) {
        self.configuration = configuration; self.auth = auth; self.deviceVault = deviceVault; self.transport = transport
    }
    public func enroll(householdID: String, grantID: String? = nil) async throws -> HouseholdBootstrap {
        guard UUID(uuidString: householdID) != nil else { throw ClientError.configuration }
        if let grantID, UUID(uuidString: grantID) == nil { throw ClientError.configuration }
        generation = UUID(); enrollment = nil; self.householdID = nil; subject = nil; memberID = nil
        selectedGrantID = grantID; selectedShopID = nil
        let start = generation
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        // Reuse the same enrolled device after a crash. The service validates current identity/session binding.
        if let saved = try deviceVault.read(), let bytes = saved.data(using: .utf8),
           let record = try? JSONDecoder().decode(StoredEnrollment.self, from: bytes),
           record.householdID == householdID, record.subject == access.identity.subject {
            enrollment = record.device; self.householdID = householdID; subject = access.identity.subject
            selectedGrantID = grantID ?? record.grantID
            selectedShopID = selectedGrantID == nil ? record.shopID : nil
            return try await bootstrap()
        }
        let device: DeviceEnrollment = try await transport.json(request(base: configuration.baseURL,
            path: "v1/households/\(householdID)/devices", method: "POST", token: access.accessToken, body: Data("{}".utf8)))
        guard generation == start else { throw ClientError.cancelled }
        let stored = StoredEnrollment(householdID: householdID, subject: access.identity.subject, device: device, grantID: selectedGrantID, shopID: selectedShopID)
        try deviceVault.write(String(decoding: encoded(stored), as: UTF8.self))
        enrollment = device; self.householdID = householdID; subject = access.identity.subject
        return try await bootstrap()
    }
    public func matches(_ operation: PendingOperation, memberID: String) -> Bool {
        operation.householdID == householdID && operation.memberID == memberID && operation.deviceID == enrollment?.deviceId
    }
    private func accountRequest(subject: String, path: String, body: Data? = nil) async throws -> URLRequest {
        let start = generation
        guard selectedGrantID == nil else { throw ClientError.accessEnded }
        let access = try await auth.access()
        guard generation == start, access.identity.subject == subject else { throw ClientError.accessEnded }
        return request(base: configuration.baseURL, path: path, method: body == nil ? "GET" : "POST",
                       token: access.accessToken, body: body)
    }
    public func deletionPreview(subject: String) async throws -> DeletionPreview {
        let req = try await accountRequest(subject: subject, path: "v1/privacy/deletion-preview")
        return try await transport.json(req)
    }
    public func requestDeletion(receipt: DeletionReceipt, households: [HouseholdDisposition]) async throws -> DeletionStatus {
        struct Input: Encodable {
            let clientKey, statusToken: String
            let confirm = true
            let households: [HouseholdDisposition]
        }
        let body = try encoded(Input(clientKey: receipt.id.uuidString.lowercased(), statusToken: receipt.statusToken, households: households))
        let req = try await accountRequest(subject: receipt.subject, path: "v1/privacy/deletions", body: body)
        let status: DeletionStatus = try await transport.json(req)
        return try status.checked(for: receipt)
    }
    public func leaveHousehold(_ intent: HouseholdExitIntent) async throws {
        guard UUID(uuidString: intent.householdID) != nil else { throw ClientError.configuration }
        let req = try await accountRequest(subject: intent.subject, path: "v1/households/\(intent.householdID)/exit", body: intent.bytes)
        struct Receipt: Decodable { let householdId: String; let left, accountDeleted: Bool }
        let receipt: Receipt = try await transport.json(req)
        guard receipt.householdId == intent.householdID, receipt.left, !receipt.accountDeleted else { throw ClientError.invalidResponse }
    }
    public func deletionStatus(_ receipt: DeletionReceipt) async throws -> DeletionStatus {
        var req = request(base: configuration.baseURL, path: "v1/privacy/jobs/\(receipt.id.uuidString.lowercased())", method: "GET")
        req.setValue(receipt.statusToken, forHTTPHeaderField: "X-Deletion-Token")
        let status: DeletionStatus = try await transport.json(req)
        return try status.checked(for: receipt)
    }
    public func workspaces() async throws -> WorkspaceList {
        let start = generation
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        let result: WorkspaceList = try await transport.json(request(base: configuration.baseURL,
            path: "v1/me/workspaces", method: "GET", token: access.accessToken))
        guard generation == start else { throw ClientError.cancelled }
        return result
    }
    public func bootstrap() async throws -> HouseholdBootstrap {
        let start = generation
        var value: HouseholdBootstrap = try await perform("bootstrap", method: "GET")
        guard generation == start else { throw ClientError.cancelled }
        guard value.household.id == householdID, value.enrolled else { throw ClientError.accessEnded }
        if selectedShopID == nil, selectedGrantID == nil, ["helper", "editor"].contains(value.role) {
            guard let grant = value.grantId, UUID(uuidString: grant) != nil else { throw ClientError.accessEnded }
            selectedGrantID = grant
            value = try await perform("bootstrap", method: "GET")
            guard generation == start else { throw ClientError.cancelled }
        }
        if let selectedGrantID {
            guard value.grantId == selectedGrantID, ["helper", "editor"].contains(value.role),
                  value.capabilities.allSatisfy({ ["helper_view", "helper_propose"].contains($0) }),
                  value.capabilities.contains("helper_view") else { await clearScope(); throw ClientError.accessEnded }
        }
        if let selectedShopID {
            guard value.grantId == nil, value.shopId.flatMap(UUID.init(uuidString:)) == selectedShopID else { throw ClientError.accessEnded }
        }
        memberID = value.memberId
        if let enrollment, let householdID, let subject {
            let stored = StoredEnrollment(householdID: householdID, subject: subject, device: enrollment, grantID: selectedGrantID, shopID: selectedShopID)
            try deviceVault.write(String(decoding: encoded(stored), as: UTF8.self))
        }
        return value
    }
    public func replayWindow() async throws -> ReplayWindow { try await perform("replay-windows", method: "POST", body: Data("{}".utf8)) }
    public func ownRequests(cursor: String? = nil) async throws -> OwnRequestsPage {
        if let cursor, UUID(uuidString: cursor) == nil { throw ClientError.configuration }
        return try await perform("requests/mine", method: "GET", query: cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
    }
    private func authorizeShopper(shopID: String) async throws {
        guard UUID(uuidString: shopID) != nil else { throw ClientError.configuration }
        let projection = try await bootstrap()
        guard projection.role == "shopper", projection.shopId == shopID,
              ["shopper_inbox", "request_preview", "shopper_commands"].allSatisfy(projection.capabilities.contains) else {
            throw ClientError.accessEnded
        }
    }
    public func selectableShops(closedAndOwned: Bool, cursor: UUID?) async throws -> HouseholdShopChoices {
        guard selectedGrantID == nil else { throw ClientError.accessEnded }
        var query = [URLQueryItem(name: "scope", value: closedAndOwned ? "owned" : "active")]
        if let cursor { query.append(.init(name: "cursor", value: cursor.uuidString.lowercased())) }
        let page: HouseholdShopChoices = try await perform("shops", method: "GET", query: query)
        guard page.shops.count <= 50, Set(page.shops.map(\.id)).count == page.shops.count,
              page.nextCursor == nil || (page.nextCursor != cursor && page.nextCursor == page.shops.last?.id) else { throw ClientError.invalidResponse }
        return page
    }
    public func selectShop(_ id: UUID?) async throws -> HouseholdBootstrap {
        guard selectedGrantID == nil, enrollment != nil else { throw ClientError.accessEnded }
        generation = UUID()
        selectedShopID = id
        return try await bootstrap()
    }
    public func shopperAssignment(shopID: UUID) async throws -> ShopperAssignment {
        let start = generation
        try await authorizeAdmin()
        guard start == generation else { throw ClientError.cancelled }
        let assignment: ShopperAssignment = try await perform("shops/\(shopID.uuidString.lowercased())/shopper-assignment", method: "GET")
        guard assignment.shopId == shopID, assignment.shopRevision > 0, assignment.authorityEpoch > 0,
              assignment.adults.contains(where: { $0.id == assignment.shopperId }) else { throw ClientError.invalidResponse }
        return assignment
    }
    public func mealPlan(shopID: UUID) async throws -> SharedMealPlan {
        let plan: SharedMealPlan = try await perform("shops/\(shopID.uuidString.lowercased())/meal-plan", method: "GET")
        guard plan.shopId == shopID, plan.meals.count <= 100, plan.proposals.count <= 100 else { throw ClientError.invalidResponse }
        return plan
    }
    public func changeMealPlanner(_ plannerID: UUID?, plan: SharedMealPlan) async throws {
        let fields: [String: JSONValue] = ["plannerId": plannerID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "grantRevision": .integer(plan.grantRevision), "authorityEpoch": .integer(plan.authorityEpoch)]
        let status: MealPlanReceipt = try await perform("shops/\(plan.shopId.uuidString.lowercased())/meal-plan/planner", method: "PUT", body: encoded(fields))
        guard status.saved else { throw ClientError.invalidResponse }
    }
    public func dismissMealMove(_ move: SharedMealPlan.Move, plan: SharedMealPlan) async throws {
        let fields: [String: JSONValue] = ["proposalId": .string(move.id.uuidString.lowercased()),
            "grantRevision": .integer(plan.grantRevision), "authorityEpoch": .integer(plan.authorityEpoch), "shopRevision": .integer(plan.shopRevision)]
        let status: MealPlanReceipt = try await perform("shops/\(plan.shopId.uuidString.lowercased())/meal-plan/dismissals", method: "POST", body: encoded(fields))
        guard status.saved else { throw ClientError.invalidResponse }
    }
    public func proposeMealMove(id: UUID, occurrenceID: UUID, day: String, plan: SharedMealPlan) async throws {
        let fields: [String: JSONValue] = ["proposalId": .string(id.uuidString.lowercased()), "occurrenceId": .string(occurrenceID.uuidString.lowercased()),
            "day": .string(day), "grantRevision": .integer(plan.grantRevision), "authorityEpoch": .integer(plan.authorityEpoch), "shopRevision": .integer(plan.shopRevision)]
        let status: MealPlanReceipt = try await perform("shops/\(plan.shopId.uuidString.lowercased())/meal-plan/proposals", method: "POST", body: encoded(fields))
        guard status.saved else { throw ClientError.invalidResponse }
    }
    public func shopperShop(shopID: String) async throws -> ShopperShop {
        let start = generation
        try await authorizeShopper(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        return try await perform("shops/\(shopID)", method: "GET")
    }
    public func shopperFinancialEvidence(shopID: String) async throws -> [ShopperFinancialEntry] {
        let start = generation
        try await authorizeShopper(shopID: shopID)
        var entries: [ShopperFinancialEntry] = []
        var seen = Set<UUID>()
        var version: ShopperFinancialPage.Version?
        var cursor: UUID?
        repeat {
            guard start == generation else { throw ClientError.cancelled }
            let page: ShopperFinancialPage = try await perform("shops/\(shopID)/financial-evidence", method: "GET",
                query: cursor.map { [.init(name: "cursor", value: $0.uuidString)] } ?? [])
            guard page.shopId == UUID(uuidString: shopID), page.evidenceSource == "shopper_reported",
                  page.entries.count <= 50, entries.count + page.entries.count <= 2000,
                  page.entries.allSatisfy({ $0.currency == "USD" && $0.amountMinor >= 0 && seen.insert($0.id).inserted }),
                  page.nextCursor == nil || (page.entries.count == 50 && page.nextCursor == page.entries.last?.id)
            else { throw ClientError.invalidResponse }
            if let version, version != page.sourceVersion { throw ClientError.service(status: 409, code: "source_changed", correlationID: nil, retryAfter: nil) }
            version = page.sourceVersion
            entries += page.entries
            cursor = page.nextCursor
        } while cursor != nil
        return entries
    }
    public func shopperInbox(shopID: String, cursor: String? = nil) async throws -> OwnRequestsPage {
        if let cursor, UUID(uuidString: cursor) == nil { throw ClientError.configuration }
        let start = generation
        try await authorizeShopper(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        return try await perform("shops/\(shopID)/inbox", method: "GET", query: cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
    }
    public func shopperPreview(shopID: String, requestID: String, base: CommandBase, decision: ShopperDecision) async throws -> ShopperPreview {
        guard UUID(uuidString: requestID) != nil, base.shopRevision > 0, base.authorityEpoch > 0,
              (base.requestRevision ?? 0) > 0 else { throw ClientError.configuration }
        struct Input: Encodable { let requestId: String; let base: CommandBase; let decision: ShopperDecision }
        let start = generation
        try await authorizeShopper(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        return try await perform("shops/\(shopID)/previews", method: "POST", body: encoded(Input(requestId: requestID, base: base, decision: decision)))
    }
    public func executeShopper(_ operation: PendingOperation) async throws -> ShopperReceipt {
        let start = generation
        guard let enrollment, operation.householdID == householdID, operation.deviceID == enrollment.deviceId else { throw ClientError.accessEnded }
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        guard envelope.clientKey == operation.clientKey, ["request.apply", "request.clarify"].contains(envelope.kind) else { throw ClientError.configuration }
        try await authorizeShopper(shopID: envelope.shopId)
        guard start == generation else { throw ClientError.cancelled }
        guard operation.memberID == memberID else { throw ClientError.accessEnded }
        return try await perform("commands", method: "POST", body: operation.bytes)
    }
    /// Shop creation is organizer-only; updates remain restricted to the currently assigned shopper.
    /// A retry retains its original shop ID, replay window, base and exact command bytes.
    public func executeSharedShop(_ operation: PendingOperation) async throws -> ShopperReceipt {
        let start = generation
        guard selectedGrantID == nil, let enrollment, operation.householdID == householdID,
              operation.deviceID == enrollment.deviceId else { throw ClientError.accessEnded }
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        guard envelope.clientKey == operation.clientKey, UUID(uuidString: envelope.shopId) != nil,
              ["shop.create", "shop.patch", "shop.freeze", "shop.reopen", "shop.transferAuthority"].contains(envelope.kind) else { throw ClientError.configuration }
        if envelope.kind == "shop.create" {
            guard envelope.base.shopRevision == 0, envelope.base.authorityEpoch == 0 else { throw ClientError.configuration }
            try await authorizeAdmin()
        } else if envelope.kind == "shop.transferAuthority" {
            try await authorizeAdmin()
        } else { try await authorizeShopper(shopID: envelope.shopId) }
        guard start == generation else { throw ClientError.cancelled }
        guard operation.memberID == memberID else { throw ClientError.accessEnded }
        return try await perform("commands", method: "POST", body: operation.bytes, creatingShop: envelope.kind == "shop.create")
    }
    /// For other native service adapters; returning a token never grants a role.
    public func currentDeviceToken(householdID: String, memberID: String) async throws -> String {
        let start = generation
        guard selectedGrantID == nil, self.householdID == householdID, self.memberID == memberID, let enrollment else { throw ClientError.accessEnded }
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        guard access.identity.subject == subject else { throw ClientError.accessEnded }
        return enrollment.deviceToken
    }
    public func prepare(envelope: CommandEnvelope, bootstrap: HouseholdBootstrap) throws -> PendingOperation {
        guard let enrollment, let householdID, bootstrap.household.id == householdID,
              bootstrap.memberId == memberID else { throw ClientError.accessEnded }
        return try PendingOperation(envelope: envelope, householdID: householdID, memberID: bootstrap.memberId, deviceID: enrollment.deviceId)
    }
    public func execute(_ operation: PendingOperation) async throws -> OwnReceipt {
        let start = generation
        guard let enrollment, operation.householdID == householdID, operation.deviceID == enrollment.deviceId else { throw ClientError.accessEnded }
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        guard envelope.clientKey == operation.clientKey,
              ["request.send", "request.edit", "request.withdraw"].contains(envelope.kind) else { throw ClientError.configuration }
        // Bootstrap revalidates the present member; stored actor/device identity cannot be silently replaced on retry.
        let projection = try await bootstrap()
        guard start == generation else { throw ClientError.cancelled }
        guard projection.memberId == operation.memberID else { throw ClientError.accessEnded }
        return try await perform("commands", method: "POST", body: operation.bytes)
    }
    public func executeMembership(_ intent: MembershipIntent) async throws -> MembershipReceipt {
        let start = generation
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        guard access.identity.subject == intent.subject else { throw ClientError.accessEnded }
        if intent.kind == .create {
            struct Key: Decodable { let clientKey: String }
            guard try JSONDecoder().decode(Key.self, from: intent.bytes).clientKey == intent.id else { throw ClientError.configuration }
        }
        let value: MembershipReceipt = try await transport.json(request(base: configuration.baseURL,
            path: intent.kind == .create ? "v1/households" : "v1/invites/redeem", method: "POST", token: access.accessToken, body: intent.bytes))
        guard generation == start else { throw ClientError.cancelled }
        return value
    }
    private func authorizeAdmin() async throws {
        let value = try await bootstrap()
        guard ["organizer", "shopper"].contains(value.role), value.capabilities.contains("household_admin"), selectedGrantID == nil else { throw ClientError.accessEnded }
    }
    public func members() async throws -> HouseholdMembers {
        let start = generation; try await authorizeAdmin(); guard start == generation else { throw ClientError.cancelled }
        return try await perform("members", method: "GET")
    }
    public func createAdultInvitation(expiresInHours: Int) async throws -> IssuedInvitation {
        guard (1...168).contains(expiresInHours) else { throw ClientError.configuration }
        let start = generation; try await authorizeAdmin(); guard start == generation else { throw ClientError.cancelled }
        struct Input: Encodable { let kind = "adult_contributor"; let expiresInHours: Int }
        return try await perform("invites", method: "POST", body: encoded(Input(expiresInHours: expiresInHours)))
    }
    public func managedInvitations() async throws -> ManagedInvitations {
        let start = generation; try await authorizeAdmin(); guard start == generation else { throw ClientError.cancelled }
        return try await perform("invites", method: "GET")
    }
    public func managedHelperViews() async throws -> ManagedHelperViews {
        let start = generation; let value = try await bootstrap(); guard start == generation else { throw ClientError.cancelled }
        guard selectedGrantID == nil, value.capabilities.contains("household_admin") || value.role == "shopper" else { throw ClientError.accessEnded }
        return try await perform("views", method: "GET")
    }
    public func revoke(_ kind: RevocationKind, targetID: String) async throws -> RevocationReceipt {
        guard UUID(uuidString: targetID) != nil else { throw ClientError.configuration }
        let start = generation; let value = try await bootstrap()
        guard start == generation else { throw ClientError.cancelled }
        guard selectedGrantID == nil, value.capabilities.contains("household_admin") || (kind == .view && value.role == "shopper") else { throw ClientError.accessEnded }
        struct Input: Encodable { let kind: RevocationKind; let targetId: String }
        return try await perform("revocations", method: "POST", body: encoded(Input(kind: kind, targetId: targetID)))
    }
    public func createHelperView(shopID: String, projection: HelperProjection, mode: String, expiresInHours: Int) async throws -> IssuedInvitation {
        guard ["read", "edit"].contains(mode), (1...168).contains(expiresInHours) else { throw ClientError.configuration }
        let start = generation; try await authorizeShopper(shopID: shopID); guard start == generation else { throw ClientError.cancelled }
        struct Input: Encodable { let shopId: String; let mode: String; let expiresInHours: Int; let shopLabel: String; let language: String; let items: [HelperInstruction] }
        return try await perform("views", method: "POST", body: encoded(Input(shopId: shopID, mode: mode, expiresInHours: expiresInHours,
            shopLabel: projection.shopLabel, language: projection.language, items: projection.items)))
    }
    public func currentHelperView(grantID: String) async throws -> HelperView {
        guard UUID(uuidString: grantID) != nil, selectedGrantID == grantID else { throw ClientError.accessEnded }
        let value: HelperView = try await perform("v1/views/\(grantID)/current", method: "GET", absolutePath: true)
        guard value.grantId == grantID else { throw ClientError.invalidResponse }
        return value
    }
    public func prepareHelperProposal(grantID: String, baseRevision: Int, correction: String) async throws -> HelperProposalIntent {
        let start = generation
        let view = try await currentHelperView(grantID: grantID)
        guard start == generation else { throw ClientError.cancelled }
        guard view.canPropose, let householdID, let memberID, let enrollment else { throw ClientError.accessEnded }
        guard view.revision == baseRevision else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
        return try .init(householdID: householdID, memberID: memberID, deviceID: enrollment.deviceId,
                         grantID: grantID, baseRevision: baseRevision, correction: correction)
    }
    public func executeHelperProposal(_ intent: HelperProposalIntent) async throws -> HelperProposalReceipt {
        let start = generation
        guard intent.householdID == householdID, intent.memberID == memberID, intent.deviceID == enrollment?.deviceId,
              intent.grantID == selectedGrantID else { throw ClientError.accessEnded }
        struct Key: Decodable { let clientKey: String }
        guard try JSONDecoder().decode(Key.self, from: intent.bytes).clientKey == intent.id else { throw ClientError.configuration }
        let view = try await currentHelperView(grantID: intent.grantID)
        guard start == generation else { throw ClientError.cancelled }
        guard view.canPropose else { throw ClientError.accessEnded }
        return try await perform("v1/views/\(intent.grantID)/proposals", method: "POST", body: intent.bytes, absolutePath: true)
    }
    public func managedHelperProjection(grantID: String, shopID: String) async throws -> ManagedHelperProjection {
        guard UUID(uuidString: grantID) != nil, selectedGrantID == nil else { throw ClientError.configuration }
        let start = generation; try await authorizeShopper(shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        let result: ManagedHelperProjection = try await perform("views/\(grantID)", method: "GET")
        guard result.grantId == grantID, result.shopId == shopID, result.revision > 0,
              ["read", "edit"].contains(result.mode), validHelperTimestamp(result.asOf), validHelperTimestamp(result.expiresAt)
        else { throw ClientError.invalidResponse }
        do { try result.projection.validateReviewed() } catch { throw ClientError.invalidResponse }
        return result
    }
    public func managedHelperProposal(grantID: String, proposalID: String, shopID: String) async throws -> HelperProposal {
        guard UUID(uuidString: proposalID) != nil else { throw ClientError.configuration }
        let start = generation
        _ = try await managedHelperProjection(grantID: grantID, shopID: shopID)
        guard start == generation else { throw ClientError.cancelled }
        let result: HelperProposal = try await perform("views/\(grantID)/proposals/\(proposalID)", method: "GET")
        guard result.proposalId == proposalID, result.grantId == grantID, result.proposalRevision > 0,
              result.baseRevision > 0, validHelperTimestamp(result.createdAt),
              ["pending", "reviewed", "dismissed"].contains(result.status) else { throw ClientError.invalidResponse }
        if result.status == "pending" {
            guard result.resolution == nil else { throw ClientError.invalidResponse }
        } else {
            guard let resolution = result.resolution, UUID(uuidString: resolution.mutationId) != nil,
                  resolution.revision > 0, validHelperTimestamp(resolution.resolvedAt),
                  resolution.decision == (result.status == "reviewed" ? "replaced" : "dismissed") else { throw ClientError.invalidResponse }
        }
        return result
    }
    public func prepareHelperReview(current: ManagedHelperProjection, proposal: HelperProposal? = nil,
                                    decision: HelperReviewDecision, projection: HelperProjection? = nil) async throws -> HelperReviewIntent {
        let start = generation
        let fresh = try await managedHelperProjection(grantID: current.grantId, shopID: current.shopId)
        guard start == generation else { throw ClientError.cancelled }
        guard fresh == current else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
        if let proposal {
            guard proposal.grantId == current.grantId, proposal.status == "pending", proposal.proposalRevision > 0 else { throw ClientError.configuration }
            let freshProposal = try await managedHelperProposal(grantID: current.grantId, proposalID: proposal.proposalId, shopID: current.shopId)
            guard start == generation else { throw ClientError.cancelled }
            guard freshProposal == proposal else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
        }
        guard let subject, let householdID, let memberID, let enrollment else { throw ClientError.accessEnded }
        return try HelperReviewIntent(subject: subject, householdID: householdID, memberID: memberID, deviceID: enrollment.deviceId,
                                      current: current, proposal: proposal, decision: decision, projection: projection)
    }
    public func executeHelperReview(_ intent: HelperReviewIntent) async throws -> HelperReviewReceipt {
        try intent.validate()
        let start = generation
        guard selectedGrantID == nil, intent.subject == subject, intent.householdID == householdID,
              intent.memberID == memberID, intent.deviceID == enrollment?.deviceId else { throw ClientError.accessEnded }
        // Revalidate live shopper/grant authority, but allow the original base to replay a committed receipt.
        _ = try await managedHelperProjection(grantID: intent.grantID, shopID: intent.shopID)
        guard start == generation else { throw ClientError.cancelled }
        guard intent.subject == subject, intent.householdID == householdID, intent.memberID == memberID,
              intent.deviceID == enrollment?.deviceId else { throw ClientError.accessEnded }
        let path = intent.proposalID.map { "views/\(intent.grantID)/proposals/\($0)/resolve" } ?? "views/\(intent.grantID)/replacements"
        let receipt: HelperReviewReceipt = try await perform(path, method: "POST", body: intent.bytes)
        try receipt.validate(for: intent)
        return receipt
    }
    /// Replaying the durable mutation returns its original receipt, even after later projection edits.
    /// A proposal status read alone cannot prove that this particular action committed.
    public func reconcileHelperReview(_ intent: HelperReviewIntent) async throws -> HelperReviewReceipt {
        try await executeHelperReview(intent)
    }
    public func helperProposals(grantID: String, cursor: String? = nil) async throws -> HelperProposals {
        guard UUID(uuidString: grantID) != nil, selectedGrantID == nil else { throw ClientError.configuration }
        if let cursor, UUID(uuidString: cursor) == nil { throw ClientError.configuration }
        let page: HelperProposals = try await perform("views/\(grantID)/proposals", method: "GET",
            query: cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
        guard page.proposals.count <= 100, page.proposals.allSatisfy({ $0.grantId == grantID }),
              page.nextCursor == nil || (page.nextCursor != cursor && page.nextCursor == page.proposals.last?.id)
        else { throw ClientError.invalidResponse }
        return page
    }
    public func guardianConsents() async throws -> GuardianConsents {
        guard selectedGrantID == nil else { throw ClientError.accessEnded }
        return try await perform("guardian/consents", method: "GET")
    }
    public func withdrawConsent(consentID: String) async throws -> ConsentWithdrawalReceipt {
        guard UUID(uuidString: consentID) != nil, selectedGrantID == nil else { throw ClientError.configuration }
        return try await perform("guardian/consents/\(consentID)/revoke", method: "POST", body: Data("{}".utf8))
    }
    public func revokeCurrentDevice() async throws {
        guard let householdID, let enrollment else { return }
        let start = generation
        do {
            let access = try await auth.access()
            guard start == generation else { throw ClientError.cancelled }
            var req = request(base: configuration.baseURL, path: "v1/households/\(householdID)/devices/current",
                              method: "DELETE", token: access.accessToken)
            req.setValue(enrollment.deviceToken, forHTTPHeaderField: "X-Device-Token")
            _ = try await transport.send(req)
            if start == generation { await clearScope() }
        } catch {
            if start == generation { await clearScope() }
            throw error
        }
    }
    // These routes independently verify current adult/shopper ownership and paid seats where required.
    // Historical shops need not be the bootstrap's currently active shop.
    private func historyContext() async throws {
        guard selectedGrantID == nil else { throw ClientError.accessEnded }
        let start = generation
        let scope = try await bootstrap()
        guard generation == start else { throw ClientError.cancelled }
        guard selectedGrantID == nil, !["helper", "editor"].contains(scope.role),
              subject != nil, memberID != nil, enrollment != nil else { throw ClientError.accessEnded }
    }
    private func historyRead<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> T {
        let start = generation; try await historyContext()
        guard generation == start else { throw ClientError.cancelled }
        return try await perform(path, method: method, body: body, query: query)
    }
    private func historyCursor(_ cursor: String?) throws -> [URLQueryItem] {
        if let cursor { guard HistoryValidation.ids([cursor]) else { throw ClientError.configuration }; return [.init(name: "cursor", value: cursor)] }
        return []
    }
    private func validateHistoryPage(ids: [String], next: String?, cursor: String?, limit: Int) throws {
        guard ids.count <= limit, HistoryValidation.uniqueIDs(ids),
              !ids.contains(where: { id in cursor.map { HistoryValidation.sameID(id, $0) } == true }) else { throw ClientError.invalidResponse }
        if let next {
            guard ids.count == limit, let last = ids.last, HistoryValidation.sameID(next, last),
                  cursor.map({ !HistoryValidation.sameID($0, next) }) ?? true else { throw ClientError.invalidResponse }
        }
    }
    public func historyOwnedShops(cursor: String? = nil) async throws -> HistoryOwnedShopPage {
        let query = try [.init(name: "scope", value: "owned")] + historyCursor(cursor)
        let page: HistoryOwnedShopPage = try await historyRead("shops", query: query)
        try validateHistoryPage(ids: page.shops.map(\.shopId), next: page.nextCursor, cursor: cursor, limit: 50)
        guard page.shops.allSatisfy({ $0.role == "shopper" && ["draft", "frozen", "placed", "closed"].contains($0.phase) && $0.revision > 0 && $0.authorityEpoch > 0 && HistoryValidation.date($0.createdAt) != nil }) else { throw ClientError.invalidResponse }
        return page
    }
    public func priceObservations(cursor: String? = nil) async throws -> HistoryPriceObservationPage {
        let page: HistoryPriceObservationPage = try await historyRead("price-observations", query: historyCursor(cursor))
        try validateHistoryPage(ids: page.observations.map(\.id), next: page.nextCursor, cursor: cursor, limit: 100)
        do { for observation in page.observations { try observation.validate() } } catch { throw ClientError.invalidResponse }
        return page
    }
    public func priceObservation(observationID: String) async throws -> HistoryPriceObservation {
        guard HistoryValidation.ids([observationID]) else { throw ClientError.configuration }
        struct Response: Decodable, Sendable { let observation: HistoryPriceObservation }
        let response: Response = try await historyRead("price-observations/\(observationID)")
        guard HistoryValidation.sameID(response.observation.id, observationID) else { throw ClientError.invalidResponse }
        do { try response.observation.validate() } catch { throw ClientError.invalidResponse }
        return response.observation
    }
    public func budgetHistory(shopIDs: [String]) async throws -> HistoryPermittedSubtotal {
        guard shopIDs.count <= 100, HistoryValidation.uniqueIDs(shopIDs) else { throw ClientError.configuration }
        struct Input: Encodable { let shopIds: [String] }
        struct Response: Decodable, Sendable { let permitted: HistoryPermittedSubtotal }
        let response: Response = try await historyRead("budget-history", method: "POST", body: encoded(Input(shopIds: shopIDs)))
        try response.permitted.validate(allowedShopIDs: shopIDs)
        return response.permitted
    }
    public func budgetPeriods(cursor: String? = nil) async throws -> HistoryBudgetPeriodPage {
        let page: HistoryBudgetPeriodPage = try await historyRead("budget-periods", query: historyCursor(cursor))
        try validateHistoryPage(ids: page.periods.map(\.periodId), next: page.nextCursor, cursor: cursor, limit: 50)
        guard page.periods.allSatisfy({ $0.revision > 0 && HistoryValidation.date($0.updatedAt) != nil }) else { throw ClientError.invalidResponse }
        return page
    }
    public func savedBudgetPeriod(periodID: String) async throws -> HistorySavedBudgetPeriod {
        guard HistoryValidation.ids([periodID]) else { throw ClientError.configuration }
        let result: HistorySavedBudgetPeriod = try await historyRead("budget-periods/\(periodID)/record")
        try result.validate(id: periodID); return result
    }
    public func budgetPeriod(periodID: String) async throws -> HistoryPeriodResponse {
        guard HistoryValidation.ids([periodID]) else { throw ClientError.configuration }
        let result: HistoryPeriodResponse = try await historyRead("budget-periods/\(periodID)")
        switch result {
        case .permittedOnly(let subtotal): try subtotal.validate()
        case .complete(let complete): try complete.validate(id: periodID)
        }
        return result
    }
    private func historySource(shopID: String) async throws {
        guard HistoryValidation.ids([shopID]) else { throw ClientError.configuration }
        struct Source: Decodable, Sendable { let shopId: String; let sourceVersion: HistorySourceVersion; let evidenceSource: String }
        let source: Source = try await historyRead("shops/\(shopID)/financial-evidence")
        guard HistoryValidation.sameID(source.shopId, shopID), source.evidenceSource == "shopper_reported" else { throw ClientError.invalidResponse }
        try source.sourceVersion.validate()
    }
    private func matchesHistory(subject: String, household: String, member: String, device: String) throws {
        guard selectedGrantID == nil, self.subject == subject, householdID == household, memberID == member, enrollment?.deviceId == device else { throw ClientError.accessEnded }
    }
    public func authorizePriceObservation(_ intent: PriceObservationIntent) async throws {
        try intent.validate()
        try matchesHistory(subject: intent.subject, household: intent.householdID, member: intent.memberID, device: intent.deviceID)
        let start = generation
        try await historySource(shopID: intent.observation.shopId)
        guard generation == start else { throw ClientError.cancelled }
        try matchesHistory(subject: intent.subject, household: intent.householdID, member: intent.memberID, device: intent.deviceID)
    }
    public func preparePriceObservation(_ observation: HistoryPriceObservation) async throws -> PriceObservationIntent {
        try observation.validate()
        let start = generation; try await historySource(shopID: observation.shopId)
        guard generation == start else { throw ClientError.cancelled }
        guard let subject, let householdID, let memberID, let enrollment else { throw ClientError.accessEnded }
        return try .init(subject: subject, householdID: householdID, memberID: memberID, deviceID: enrollment.deviceId, observation: observation)
    }
    public func executePriceObservation(_ intent: PriceObservationIntent) async throws -> PriceObservationReceipt {
        let start = generation; try await authorizePriceObservation(intent)
        guard generation == start else { throw ClientError.cancelled }
        let receipt: PriceObservationReceipt = try await perform("price-observations", method: "POST", body: intent.bytes)
        guard receipt.recorded, HistoryValidation.sameID(receipt.observationId, intent.observation.id), HistoryValidation.sameID(receipt.shopId, intent.observation.shopId) else { throw ClientError.invalidResponse }
        return receipt
    }
    public func authorizeBudgetPeriod(_ intent: BudgetPeriodIntent) async throws {
        try intent.validate()
        try matchesHistory(subject: intent.subject, household: intent.householdID, member: intent.memberID, device: intent.deviceID)
        let start = generation
        let permitted = try await budgetHistory(shopIDs: intent.period.shopIds)
        guard generation == start else { throw ClientError.cancelled }
        guard permitted.shops.count == intent.period.shopIds.count else { throw ClientError.accessEnded }
        if intent.baseRevision > 0 {
            let current = try await budgetPeriod(periodID: intent.period.id)
            guard generation == start else { throw ClientError.cancelled }
            // A cached pending envelope must not restore details hidden by current source access.
            guard case .complete = current else { throw ClientError.accessEnded }
        }
        try matchesHistory(subject: intent.subject, household: intent.householdID, member: intent.memberID, device: intent.deviceID)
    }
    public func prepareBudgetPeriod(_ period: HistoryBudgetPeriod, baseRevision: Int) async throws -> BudgetPeriodIntent {
        try period.validate(); guard baseRevision >= 0, baseRevision < Int.max else { throw ClientError.configuration }
        let start = generation
        let permitted = try await budgetHistory(shopIDs: period.shopIds)
        guard generation == start else { throw ClientError.cancelled }
        guard permitted.shops.count == period.shopIds.count else { throw ClientError.accessEnded }
        if baseRevision > 0 {
            let current = try await savedBudgetPeriod(periodID: period.id)
            guard generation == start else { throw ClientError.cancelled }
            guard current.revision == baseRevision else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
            for old in current.period.reservations where old.state != .reserved {
                guard period.reservations.contains(old) else { throw ClientError.service(status: 409, code: "reservation_final", correlationID: nil, retryAfter: nil) }
            }
        }
        guard let subject, let householdID, let memberID, let enrollment else { throw ClientError.accessEnded }
        return try .init(subject: subject, householdID: householdID, memberID: memberID, deviceID: enrollment.deviceId, baseRevision: baseRevision, period: period)
    }
    public func executeBudgetPeriod(_ intent: BudgetPeriodIntent) async throws -> BudgetPeriodReceipt {
        let start = generation; try await authorizeBudgetPeriod(intent)
        guard generation == start else { throw ClientError.cancelled }
        let receipt: BudgetPeriodReceipt = try await perform("budget-periods", method: "POST", body: intent.bytes)
        guard receipt.saved, HistoryValidation.sameID(receipt.periodId, intent.period.id), receipt.revision == intent.baseRevision + 1 else { throw ClientError.invalidResponse }
        return receipt
    }

    public func clearScope() async {
        generation = UUID(); enrollment = nil; householdID = nil; subject = nil; memberID = nil; selectedGrantID = nil; selectedShopID = nil
        try? deviceVault.clear()
    }
    private func perform<T: Decodable & Sendable>(_ path: String, method: String, body: Data? = nil,
                                                 query: [URLQueryItem] = [], absolutePath: Bool = false, creatingShop: Bool = false) async throws -> T {
        let start = generation
        guard let householdID, let enrollment else { throw ClientError.sessionNeeded }
        if let selectedGrantID, path != "bootstrap",
           path != "v1/views/\(selectedGrantID)/current", path != "v1/views/\(selectedGrantID)/proposals" { throw ClientError.accessEnded }
        let access = try await auth.access()
        guard generation == start else { throw ClientError.cancelled }
        guard access.identity.subject == subject else { await clearScope(); throw ClientError.accessEnded }
        var req = request(base: configuration.baseURL, path: "v1/households/\(householdID)/\(path)",
                          method: method, token: access.accessToken, body: body)
        if absolutePath { req.url = configuration.baseURL.appendingPathComponent(path) }
        req.setValue(enrollment.deviceToken, forHTTPHeaderField: "X-Device-Token")
        req.setValue(householdID, forHTTPHeaderField: "X-Household-ID")
        if let selectedGrantID { req.setValue(selectedGrantID, forHTTPHeaderField: "X-View-Grant-ID") }
        if let selectedShopID, !creatingShop { req.setValue(selectedShopID.uuidString.lowercased(), forHTTPHeaderField: "X-Shop-ID") }
        if !query.isEmpty {
            var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = query; req.url = components.url
        }
        do {
            let result: T = try await transport.json(req)
            guard generation == start else { throw ClientError.cancelled }
            return result
        } catch {
            guard generation == start else { throw ClientError.cancelled }
            if let error = error as? ClientError, error == .accessEnded || error == .sessionNeeded { await clearScope() }
            throw error
        }
    }
}

/// An atomic, device-private outbox. Saving here is not a shared commit, and callers must show waiting until a receipt arrives.
public actor OperationOutbox {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func operations() throws -> [PendingOperation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PendingOperation].self, from: Data(contentsOf: url))
    }
    public func append(_ operation: PendingOperation) throws {
        var all = try operations()
        if let old = all.first(where: { $0.id == operation.id }) {
            guard old == operation else { throw ClientError.service(status: 409, code: "key_reused", correlationID: nil, retryAfter: nil) }
            return
        }
        all.append(operation); try save(all)
    }
    public func remove(_ id: String) throws { try save(operations().filter { $0.id != id }) }
    public func purge(householdID: String, memberID: String) throws {
        try save(operations().filter { $0.householdID != householdID || $0.memberID != memberID })
    }
    public func purge() throws { try save([]) }
    private func save(_ all: [PendingOperation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try encoded(all).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encoded(all).write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var protectedURL = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }
}

private struct StoredEnrollment: Codable { let householdID: String; let subject: String; let device: DeviceEnrollment; let grantID: String?; let shopID: UUID? }
