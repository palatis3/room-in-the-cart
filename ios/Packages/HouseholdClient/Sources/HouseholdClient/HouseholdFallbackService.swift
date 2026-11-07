import Foundation

private struct FallbackMutation: Codable {
    let v: Int
    let clientKey, candidateId: UUID
    let shopRevision, authorityEpoch, registryRevision: Int
    @RecoveryNullable var baseRevision: Int?
    let action: String
    let reviewed: Bool
    let source: SharedFallbackSource?
    let recipe: SharedFallbackRecipe?
    let usual: Bool?

    func validate() throws {
        guard v == 1, reviewed, (1...Int(Int32.max)).contains(shopRevision), (1...Int(Int32.max)).contains(authorityEpoch),
              (0..<Int(Int32.max)).contains(registryRevision), baseRevision.map({ (1..<Int(Int32.max)).contains($0) }) ?? true else {
            throw ClientError.configuration
        }
        switch action {
        case "accept":
            guard let source, let recipe, usual != nil else { throw ClientError.configuration }
            try source.validate()
            try recipe.validate()
            guard try encoded(recipe).count <= 512 * 1024 else { throw ClientError.configuration }
        case "revoke":
            guard baseRevision != nil, source == nil, recipe == nil, usual == nil else { throw ClientError.configuration }
        default: throw ClientError.configuration
        }
    }
}

extension HouseholdService {
    public func acceptedFallbacks(shopID: String) async throws -> SharedFallbackLibrary {
        let start = generation
        try await authorizeShopper(shopID: shopID, capability: "accepted_fallbacks")
        guard start == generation else { throw ClientError.cancelled }
        let actor = try guardianContext()
        var library: SharedFallbackLibrary = try await perform("shops/\(shopID)/accepted-fallbacks", method: "GET")
        guard library.shopId == UUID(uuidString: shopID) else { throw ClientError.invalidResponse }
        try library.validate()
        guard library.candidates.count <= 20 else { throw ClientError.invalidResponse }
        var cursor = library.nextCursor
        while let after = cursor {
            guard library.candidates.last?.id == after, library.candidates.count < 100 else { throw ClientError.invalidResponse }
            guard start == generation else { throw ClientError.cancelled }
            let next: SharedFallbackLibrary = try await perform("shops/\(shopID)/accepted-fallbacks", method: "GET",
                query: [.init(name: "cursor", value: after.uuidString.lowercased())])
            guard next.shopId == library.shopId, next.shopRevision == library.shopRevision, next.registryRevision == library.registryRevision,
                  next.authorityEpoch == library.authorityEpoch, !next.candidates.isEmpty, next.candidates.count <= 20, next.candidates[0].id.uuidString > after.uuidString else {
                throw ClientError.invalidResponse
            }
            try next.validate()
            library.candidates += next.candidates
            cursor = next.nextCursor
        }
        library.nextCursor = nil
        try library.validate()
        guard start == generation, actor == (try guardianContext()) else { throw ClientError.cancelled }
        library.actor = actor
        return library
    }

    public func fallbackSource(_ source: SharedFallbackSource, reviewed library: SharedFallbackLibrary) async throws -> SharedFallbackSourcePreview {
        try source.validate()
        guard source != .disclosed else { throw ClientError.configuration }
        let id = library.shopId.uuidString.lowercased(), start = generation
        try await authorizeFallbackLibrary(library)
        try await authorizeAssistance(shopID: id)
        guard start == generation, library.actor == (try guardianContext()) else { throw ClientError.cancelled }
        let result: SharedFallbackSourcePreview = try await perform("shops/\(id)/accepted-fallbacks/source", method: "POST",
                                                                   body: encoded(["source": source]))
        guard result.shopId == library.shopId, result.shopRevision == library.shopRevision, result.authorityEpoch == library.authorityEpoch,
              result.registryRevision == library.registryRevision, result.source == source else { throw ClientError.invalidResponse }
        try result.recipe.validate()
        return result
    }

    func authorizeFallbackLibrary(_ library: SharedFallbackLibrary) async throws {
        let start = generation
        try await authorizeShopper(shopID: library.shopId.uuidString.lowercased(), capability: "accepted_fallbacks")
        guard start == generation else { throw ClientError.cancelled }
        guard library.actor == (try guardianContext()) else { throw ClientError.accessEnded }
    }

    public func prepareFallback(_ edit: SharedFallbackEdit, reviewed library: SharedFallbackLibrary, clientKey: UUID) async throws -> PendingFallbackWrite {
        try await authorizeFallbackLibrary(library)
        let actor = try guardianContext()
        let body: FallbackMutation
        switch edit {
        case let .accept(id, revision, source, recipe, usual):
            guard library.candidates.first(where: { $0.id == id })?.revision == revision else { throw ClientError.configuration }
            try await authorizeAssistance(shopID: library.shopId.uuidString.lowercased())
            body = .init(v: 1, clientKey: clientKey, candidateId: id, shopRevision: library.shopRevision, authorityEpoch: library.authorityEpoch,
                         registryRevision: library.registryRevision, baseRevision: revision, action: "accept", reviewed: true, source: source, recipe: recipe, usual: usual)
        case let .revoke(id, revision):
            guard library.candidates.contains(where: { $0.id == id && $0.revision == revision }) else { throw ClientError.configuration }
            body = .init(v: 1, clientKey: clientKey, candidateId: id, shopRevision: library.shopRevision, authorityEpoch: library.authorityEpoch,
                         registryRevision: library.registryRevision, baseRevision: revision, action: "revoke", reviewed: true, source: nil, recipe: nil, usual: nil)
        }
        guard library.actor == (try guardianContext()) else { throw ClientError.accessEnded }
        try body.validate()
        let pending = try PendingFallbackWrite(householdID: actor.householdID, memberID: actor.memberID, deviceID: actor.deviceID, subject: actor.subject,
                         shopId: library.shopId, candidateId: body.candidateId, clientKey: clientKey, shopRevision: library.shopRevision,
                         authorityEpoch: library.authorityEpoch, registryRevision: library.registryRevision, bytes: encoded(body))
        try pending.validate()
        return pending
    }

    public func executeFallback(_ pending: PendingFallbackWrite) async throws -> SharedFallbackReceipt {
        try pending.validate()
        let id = pending.shopId.uuidString.lowercased()
        let actor = GuardianActorBinding(subject: pending.subject, householdID: pending.householdID, memberID: pending.memberID, deviceID: pending.deviceID)
        let start = generation
        let body = try JSONDecoder().decode(FallbackMutation.self, from: pending.bytes)
        if body.action == "accept" { try await authorizeAssistance(shopID: id) }
        else { try await authorizeShopper(shopID: id, capability: "accepted_fallbacks") }
        guard start == generation else { throw ClientError.cancelled }
        guard actor == (try guardianContext()) else { throw ClientError.accessEnded }
        let receipt: SharedFallbackReceipt = try await perform("shops/\(id)/accepted-fallbacks", method: "POST", body: pending.bytes)
        guard receipt.shopId == pending.shopId, receipt.candidateId == body.candidateId, receipt.shopRevision == body.shopRevision,
              receipt.authorityEpoch == body.authorityEpoch, receipt.registryRevision == body.registryRevision + 1,
              receipt.revision == (body.baseRevision ?? 0) + 1, receipt.accepted == (body.action == "accept") else { throw ClientError.invalidResponse }
        return receipt
    }

    public func saveFallback(_ edit: SharedFallbackEdit, reviewed library: SharedFallbackLibrary, clientKey: UUID) async throws -> SharedFallbackReceipt {
        try await executeFallback(prepareFallback(edit, reviewed: library, clientKey: clientKey))
    }
}

private struct RankedFallbackRequest: Encodable {
    let v = 1
    let base: SharedRecoveryBase
    let occurrenceId: UUID
    let targetDigest: String
    let reviews: [SharedFallbackReview]
    @RecoveryNullable var trip: SharedFallbackTrip?
}

extension HouseholdService {
    @discardableResult func authorizeAssistance(shopID: String) async throws -> Date {
        guard let until = try await assistanceValidUntil(shopID: shopID) else {
            throw ClientError.service(status: 403, code: "membership_inactive", correlationID: nil, retryAfter: nil)
        }
        return until
    }
    public func assistanceValidUntil(shopID: String) async throws -> Date? {
        struct Snapshot: Decodable {
            struct Seat: Decodable { let userID: UUID; let isAdult: Bool }
            let householdID: UUID
            let status, validUntil: String
            let seats: [Seat]
        }
        let start = generation
        let scope = try await authorizeShopper(shopID: shopID, capability: "accepted_fallbacks")
        guard start == generation else { throw ClientError.cancelled }
        let membership: Snapshot = try await perform("entitlements", method: "GET")
        guard membership.householdID == UUID(uuidString: scope.household.id),
              let until = householdTimestamp(membership.validUntil) else { throw ClientError.invalidResponse }
        guard ["active", "grace"].contains(membership.status), until > Date(),
              membership.seats.contains(where: { $0.isAdult && $0.userID == UUID(uuidString: scope.memberId) }) else { return nil }
        return until
    }

    public func recoveryOptions(_ reviews: [SharedFallbackReview], trip: SharedFallbackTrip?, for occurrenceID: UUID, reviewed page: SharedRecoveryPage,
                                library: SharedFallbackLibrary) async throws -> SharedFallbackOptions {
        try await authorizeFallbackLibrary(library)
        guard library.shopId == page.shopId, page.base.shopRevision == library.shopRevision, page.base.authorityEpoch == library.authorityEpoch,
              let target = page.meals.first(where: { $0.id == occurrenceID }), reviews.count <= 100,
              Set(reviews.map(\.candidateId)).count == reviews.count else { throw ClientError.configuration }
        try trip?.validate()
        for review in reviews {
            guard let candidate = library.candidates.first(where: { $0.id == review.candidateId }) else { throw ClientError.configuration }
            try review.validate(candidate, page: page)
        }
        let start = generation, id = page.shopId.uuidString.lowercased()
        let digest = try target.targetDigest()
        let until = try await authorizeAssistance(shopID: id)
        let coverage = try await effectiveCoverage(reviewed: page)
        var remaining = reviews[...]
        var combined: SharedFallbackOptions?
        repeat {
            guard start == generation, library.actor == (try guardianContext()) else { throw ClientError.cancelled }
            let body = RankedFallbackRequest(base: page.base, occurrenceId: occurrenceID, targetDigest: digest, reviews: Array(remaining), trip: trip)
            let result: SharedFallbackOptions = try await perform("shops/\(id)/meal-recovery/options", method: "POST", body: encoded(body))
            guard result.registryRevision == library.registryRevision else {
                throw ClientError.service(status: 409, code: "stale_fallback", correlationID: nil, retryAfter: nil)
            }
            if let offset = result.nextReviewIndex, offset <= 0 || offset >= remaining.count { throw ClientError.invalidResponse }
            let count = result.nextReviewIndex ?? remaining.count
            try result.validate(page: page, library: library, occurrence: occurrenceID, reviews: Array(remaining.prefix(count)), trip: trip)
            for option in result.options {
                try option.validateRetainedCoverage(coverage)
            }
            if combined == nil {
                combined = result
            } else {
                combined?.options.append(contentsOf: result.options)
                combined?.conditional.append(contentsOf: result.conditional)
            }
            remaining = remaining.dropFirst(count)
        } while !remaining.isEmpty
        guard var result = combined, start == generation else { throw ClientError.cancelled }
        result.nextReviewIndex = nil
        result.options.sort { lhs, rhs in
            (lhs.packCount, lhs.extraCashMinor, lhs.minutes, lhs.id.uuidString) < (rhs.packCount, rhs.extraCashMinor, rhs.minutes, rhs.id.uuidString)
        }
        let usualIDs = Set(library.candidates.filter(\.usual).map(\.id))
        result.usualMinutes = result.options.filter { usualIDs.contains($0.id) }.map(\.minutes).min()
        guard until > Date() else { throw ClientError.service(status: 403, code: "membership_inactive", correlationID: nil, retryAfter: nil) }
        result.assistanceValidUntil = until
        return result
    }
}

extension PendingFallbackWrite {
    public func validate() throws {
        guard !bytes.isEmpty, bytes.count <= 540_000, !subject.isEmpty, subject.utf8.count <= 2048,
              [householdID, memberID, deviceID].allSatisfy({ UUID(uuidString: $0) != nil }) else { throw ClientError.configuration }
        let body = try JSONDecoder().decode(FallbackMutation.self, from: bytes)
        try body.validate()
        guard try encoded(body) == bytes, body.clientKey == clientKey, body.candidateId == candidateId, body.shopRevision == shopRevision,
              body.authorityEpoch == authorityEpoch, body.registryRevision == registryRevision else { throw ClientError.configuration }
    }
}
