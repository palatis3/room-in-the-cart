import Foundation

extension SharedTrackingIntent {
    func validate(page: SharedTrackingPage) throws {
        try base.validate(page: page, context: base.context)
        try demandRequire(base.graphRevision < Int(Int32.max) && base.shopRevision < Int(Int32.max))
        if case .recover = kind { try demandRequire(page.projection != nil && page.state == nil) }
        else {
            try demandRequire(page.state != nil && page.projection == nil)
            try demandRequire((kind.mode == "adopt") == (base.graphRevision == 0))
        }
        if actionSources != nil { try demandRequire(kind.mode == "adopt") }
        if let packs = kind.packs {
            try demandRequire(packs.count <= 200 && demandUnique(packs.map(\.lineId)))
            for pack in packs { try demandIDs([pack.lineId]); try pack.usablePerPack?.validate() }
        }
        if let action = kind.action { _ = try SharedTrackingAction(action) }
        switch kind {
        case .adopt(let action, let change, _):
            if let actionSources { try actionSources.validate(page: page, action: action, requestPreview: requestPreview) }
            else { guard case .patch(let body) = action, body.mealEdit == nil else { throw ClientError.configuration } }
            try change.validate()
        case .change(_, let change, _, let ids):
            try change.validate(); try demandIDs(ids.map(Optional.some)); try demandRequire(ids.count <= 2000 && demandUnique(ids))
        case .review(let action, _):
            guard case .patch(let body) = action, body.mealEdit == nil else { throw ClientError.configuration }
        case .firstAdoptionUndo(let id, _): try demandIDs([id])
        case .rebind(let bindings):
            try demandRequire(!bindings.isEmpty && bindings.count <= 2000 && demandUnique(bindings.map(\.factId)))
            for binding in bindings {
                try binding.line.validate(); try binding.packReview.usablePerPack?.validate()
                try demandRequire(page.state?.unbound.contains { $0.factId == binding.factId && $0.transferred != nil } == true)
                try demandRequire(binding.line.trashedAt == nil && binding.line.id == binding.basket.id && binding.line.name == binding.basket.name && binding.packReview.lineId == binding.line.id)
            }
        case .recover: break
        }
        if case .request(let action) = kind.action {
            guard let requestPreview else { throw ClientError.configuration }
            try demandRequire(requestPreview.previewId == action.previewId.string && requestPreview.shopRevision == base.shopRevision && requestPreview.authorityEpoch == base.authorityEpoch)
            try demandRequire(demandRevision(requestPreview.requestRevision) && requestPreview.requestRevision < Int(Int32.max) && ["add", "link"].contains(requestPreview.choice))
            try demandRequire(!requestPreview.requiresOverageAcceptance || action.acceptOverage)
            try demandRequire(!requestPreview.requiresUnknownAcceptance || action.acceptUnknown)
        } else { try demandRequire(requestPreview == nil) }
    }
    func requireFreshRequest(now: Date = Date()) throws {
        if let requestPreview { try demandRequire(demandTime(requestPreview.expiresAt).map { $0 > now } == true) }
    }
}
extension SharedTrackingPickupDisclosure {
    func validate(state: SharedTrackingState) throws {
        try coverage.validate(state: state)
        try demandRequire(basket == state.basket && packReviews == state.packReviews && unbound.count == state.unbound.count)
        for (disclosed, entry) in zip(unbound, state.unbound) {
            try demandRequire(disclosed.fact == state.catalog.first { $0.id == entry.factId } && disclosed.transferred == entry.transferred)
        }
        try demandRequire(unpricedBasketIds == state.basket.filter { $0.priceMinor == nil }.map(\.id))
        let unresolved = state.packReviews.filter { pack in
            pack.usablePerPack == nil || coverage.trackedSubtotals.first { $0.lineId == pack.lineId }?.quantity == nil ||
                state.graph.contributions.contains { row in row.lineId == pack.lineId && row.removedAt == nil && (row.sourceExclusions ?? []).contains { $0.resolution == .unresolved } }
        }.map(\.lineId)
        try demandRequire(unresolvedPackIds == unresolved)
    }
}
extension SharedTrackingCandidateReview {
    func validate() throws {
        try intent.validate(page: page)
        let after = candidate.after, before = page.graph
        try demandRequire(after.graph.householdId == before.householdId && after.graph.shopId == before.shopId && after.graph.revision == before.revision + 1)
        try demandRequire(after.authorityEpoch == page.authorityEpoch && after.privacyRevision == page.privacyRevision)
        try demandRequire(Set(before.usedIds).isSubset(of: Set(after.graph.usedIds)))
        if let catalog = intent.actionSources {
            try demandRequire(candidate.action == catalog.normalizedAction && after.catalog == catalog.sources.map(\.fact))
        } else if let expected = intent.kind.action { try demandRequire(candidate.action.command == expected) }
        else {
            guard case .patch(let body) = candidate.action.command else { throw ClientError.invalidResponse }
            if body.mealEdit != nil { guard case .compoundAdoptionUndo = candidate.disclosure.changes else { throw ClientError.invalidResponse } }
        }
        if let packs = intent.kind.packs { try demandRequire(after.packReviews == packs) }
        if case .patch(let body) = candidate.action.command {
            let rows = body.lines.map { line in (line.lineId, line) }
            try demandRequire(rows.count == after.basket.count)
            for basket in after.basket {
                guard let row = rows.first(where: { $0.0 == basket.id.string })?.1 else { throw ClientError.invalidResponse }
                try demandRequire(row.originalItem == basket.name && row.packs == basket.packs && row.unitPriceMinor == basket.priceMinor && row.feeEligible == basket.feeEligible)
            }
        }
        if case .request(let request) = candidate.action.command {
            let facts = after.catalog.filter { if case .request(let id, _) = $0.source { return id == request.requestId }; return false }
            guard facts.count == 1, case .request(_, let acceptedRevision) = facts[0].source,
                  let preview = intent.requestPreview else { throw ClientError.invalidResponse }
            // Explicit original preview, not an arbitrary historic source, is the base.
            try demandRequire(acceptedRevision == preview.requestRevision && facts[0].revision == preview.requestRevision)
        }
        try demandRequire(candidate.disclosure.money.before == page.checkout)
        let pickup = candidate.disclosure.pickup
        try pickup.validate(state: after)
        switch (intent.kind, candidate.disclosure.changes) {
        case (.adopt, .none), (.change, .none): break
        case (.review, .none):
            var expected = before; expected.revision += 1
            try demandRequire(after.graph == expected && after.catalog == page.state?.catalog && after.bindings == page.state?.bindings && after.unbound == page.state?.unbound)
        case (.firstAdoptionUndo, .compoundAdoptionUndo(let disclosure)):
            try disclosure.validate(page: page, candidate: candidate)
        case (.firstAdoptionUndo(let target, _), .firstAdoptionUndo(let disclosure)):
            try demandRequire(disclosure.targetOperationId == target && disclosure.beforeCoverage == page.coverage && disclosure.afterCoverage == pickup.coverage)
            try demandRequire(after.catalog == page.state?.catalog)
            let assertions = disclosure.reversedAssertions
            try demandRequire(assertions.lines.count <= 200 && assertions.contributions.count <= 2000 && assertions.edges.count <= 4000 && assertions.packReviews.count <= 200)
            try demandRequire(demandUnique(assertions.lines.map(\.id)) && demandUnique(assertions.contributions.map(\.id)) && demandUnique(assertions.edges.map(\.id)))
            for row in assertions.lines { try demandRequire(before.lines.contains(row)) }
            for row in assertions.contributions { try demandRequire(before.contributions.contains(row)) }
            for row in assertions.edges { try demandRequire(before.edges.contains(row)) }
            for pack in assertions.packReviews { try demandRequire(page.state?.packReviews.contains(pack) == true) }
            try demandRequire(disclosure.basketChanges.count <= 200 && demandUnique(disclosure.basketChanges.map(\.id)))
            for delta in disclosure.basketChanges { try demandRequire((delta.before != nil || delta.after != nil) && (delta.before.map { $0.id == delta.id } ?? true) && (delta.after.map { $0.id == delta.id } ?? true)) }
            let newlyUnbound = after.unbound.filter { u in page.state?.unbound.contains { $0.factId == u.factId } == false }.map(\.factId)
            try demandRequire(demandUnique(disclosure.transferredFactIds) && Set(disclosure.transferredFactIds) == Set(newlyUnbound))
            let reversed = Set(assertions.contributions.map(\.id))
            try demandRequire(disclosure.retainedLaterContributionIds == after.graph.contributions.filter { $0.removedAt == nil && !reversed.contains($0.id) }.map(\.id))
        case (.rebind(let bindings), .rebind(let disclosure)):
            try demandRequire(disclosure.before == page.coverage && disclosure.after == pickup.coverage && disclosure.restored.map(\.factId) == bindings.map(\.factId))
            try demandRequire(after.catalog == page.state?.catalog && after.graph.edges == before.edges)
            for (entry, binding) in zip(disclosure.restored, bindings) {
                guard let transferred = entry.before.transferred else { throw ClientError.invalidResponse }
                try demandRequire(entry.before.factId == entry.factId && page.state?.unbound.contains(entry.before) == true)
                var expected = transferred; expected.lineId = binding.line.id
                try demandRequire(entry.after == expected && after.graph.contributions.contains(entry.after))
            }
        case (.recover, .recover(let disclosure)):
            try demandRequire(disclosure.invalidatedStateDigest == page.projection?.invalidatedStateDigest && disclosure.survivingCatalog == after.catalog && disclosure.unbound == after.unbound && disclosure.freshPackReviews == after.packReviews && disclosure.coverage == pickup.coverage)
            try demandRequire(after.catalog == page.projection?.state.catalog && after.unbound == page.projection?.state.unbound)
        default: throw ClientError.invalidResponse
        }
    }
    func requireFresh(now: Date = Date()) throws {
        guard let expiry = demandTime(candidate.expiresAt) else { throw ClientError.invalidResponse }
        try demandRequire(expiry > now && expiry <= now.addingTimeInterval(600))
        try intent.requireFreshRequest(now: now)
    }
}
extension SharedTrackingAcceptedReview {
    func validate() throws {
        try candidateReview.validate()
        try preview.moneyAcknowledgments.validate(money: preview.disclosure.money.after)
        let candidate = candidateReview.candidate
        try demandRequire(preview.previewId == candidate.candidateId && preview.expiresAt == candidate.expiresAt && preview.action == candidate.action && preview.disclosure == candidate.disclosure)
        for id in preview.disclosure.pickup.unresolvedPackIds {
            try demandRequire(candidate.after.packReviews.first { $0.lineId == id }?.acceptUnresolved == true)
        }
    }
}
