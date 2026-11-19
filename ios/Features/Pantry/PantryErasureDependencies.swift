import Foundation
import CryptoKit
import CoreDomain
import LocalStore
import RecordArchive

/// Typed dependency inspection, never an erasure command or a grant. Source facts
/// and incidental proof copies are different edges; neither authorizes deleting
/// an unrelated journey or the physical food it happens to contain.
@MainActor enum PantryErasureDependencies {
    enum Failure: Error, Equatable { case invalidContext, stale, unauthorized, capacity }
    enum Selection: Codable, Equatable {
        case lot(UUID, revision: Int64)
        case pickup(UUID, revision: Int64, payloadDigest: Data)
        case price(UUID, revision: Int64)
        case wholeOrigin
    }
    enum Role: String, Hashable { case physicalFact, sourceFact, claim, incidentalCopy, identityLink }
    enum Subject: Hashable { case lot(UUID), source(InventorySource), claim(UUID), journey(UUID), intent(UUID) }
    enum Container: Hashable {
        case inventory(InventoryRecordKey, revision: Int64)
        case pickup(UUID, revision: Int64)
        /// Caller supplies a stable archive/journal identity. It is not a live source.
        case external(String)
    }
    enum Reason: String, Hashable {
        case unknownNamespace, unknownPayloadShape, invalidPayload, foreignLineage, unresolvedLegacyLot
        case opaqueProjectionRequest, unverifiedDisposition, externalCopiesNotScanned
    }
    struct Match: Hashable { let subject: Subject; let role: Role }
    struct Inspection: Equatable {
        let container: Container
        let payloadDigest: Data
        let matches: Set<Match>
        /// Direct source carriers in this container, including unrelated food.
        /// This is impact disclosure, NOT a physical deletion list.
        let sourceFactLotIDs: Set<UUID>
        let unresolved: Set<Reason>
        let ledgerOrigins: Set<UUID>
        var containsPrivateDependency: Bool { !matches.isEmpty }
    }
    struct Preview {
        let selection: Selection
        let originID: UUID
        let inventoryRevision: Int64
        let sourceToken: InventorySourceToken
        let inspections: [Inspection]
        let explicitlySelectedLotIDs: Set<UUID>
        let ledgerOrigins: Set<UUID>
        let retainedPhysicalLotIDs: Set<UUID>
        let pickupSourceCandidateLotIDs: Set<UUID>
        let collateralPickupIDs: Set<UUID>
        let sqlHistoriesComplete: Bool
        /// SQL completion never proves ledger, journal, media or archive closure.
        let remainingScopes: Set<Reason>
        let retainedReceiptLotIDsInCollateralPickups: Set<UUID>
        let retainedReservations: [InventoryReservation]
        var needsExpandedReview: Bool { !collateralPickupIDs.isEmpty }
        var unresolvedSQLReasons: Set<Reason> {
            Set(inspections.flatMap { $0.unresolved })
        }
        var sqlDependenciesVerified: Bool { sqlHistoriesComplete && unresolvedSQLReasons.isEmpty }
    }
    struct Context {
        let originID: UUID
        let inventoryRevision: Int64
        let sourceToken: InventorySourceToken
        let lots: [InventoryLot]
        let claims: [InventoryReservation]
        let mapping: PantryLegacyMigration.Plan
        let at: Date
        fileprivate let sourceLots: [InventorySource: UUID]
        fileprivate let aliases: [UUID: Set<UUID>]

        @MainActor init(snapshot: PantryRepository.Snapshot, mapping: PantryLegacyMigration.Plan,
             sourceToken: InventorySourceToken, at: Date) throws {
            guard snapshot.state.active, snapshot.state.workspaceID == mapping.originID,
                  sourceToken.workspaceID == mapping.originID, sourceToken.generation >= 0,
                  sourceToken.digest.count == 32, at.timeIntervalSinceReferenceDate.isFinite,
                  mapping.sourceHeads.count <= PantryLegacyMigration.maximumHeads,
                  Set(mapping.sourceHeads.map(\.id)).count == mapping.sourceHeads.count else { throw Failure.invalidContext }
            _ = try InventoryProjection.build(originID: mapping.originID, lots: snapshot.lots, reservations: snapshot.reservations, at: at)
            originID = mapping.originID; inventoryRevision = snapshot.state.revision
            self.sourceToken = sourceToken; lots = snapshot.lots; claims = snapshot.reservations; self.mapping = mapping; self.at = at
            sourceLots = Dictionary(uniqueKeysWithValues: lots.map { ($0.source, $0.id) })
            var aliases: [UUID: Set<UUID>] = [:]
            for lot in lots {
                aliases[lot.id, default: []].insert(lot.id)
                if case .manual(_, let id) = lot.source { aliases[id, default: []].insert(lot.id) }
            }
            for link in mapping.sourceLinks {
                guard sourceLots[link.source] == link.lotID else { throw Failure.invalidContext }
                for reference in link.references {
                    if let id = reference.legacyLotID { aliases[id, default: []].insert(link.lotID) }
                    for id in reference.observationIDs { aliases[id, default: []].insert(link.lotID) }
                }
            }
            self.aliases = aliases
        }
    }
    private struct Target {
        let lots: Set<UUID>
        let sources: Set<InventorySource>
        let claims: Set<UUID>
        let journey: UUID?
        let all: Bool
        init(_ selection: Selection, context: Context, historicalSourceLots: Set<UUID> = []) throws {
            var ids: Set<UUID>
            switch selection {
            case let .lot(id, revision):
                guard context.lots.contains(where: { $0.id == id && $0.revision == revision }) else { throw Failure.stale }
                ids = [id]; journey = nil; all = false
            case let .pickup(id, revision, digest):
                guard let head = context.mapping.sourceHeads.first(where: { $0.id == id }),
                      head.revision == revision, Data(SHA256.hash(data: head.payload)) == digest else { throw Failure.stale }
                // These are source-carrier candidates only. A carried alias is not
                // proof of exclusive ownership and cannot silently select food.
                ids = Set(context.mapping.sourceLinks.filter { $0.references.contains { $0.journeyID == id } }.map(\.lotID)).union(historicalSourceLots)
                journey = id; all = false
            case .price: throw Failure.invalidContext
            case .wholeOrigin: ids = Set(context.lots.map(\.id)); journey = nil; all = true
            }
            // A transfer has immutable provenance on both portions. Review every linked
            // portion together so a surviving batch never loses half its physical history.
            if !all {
                var neighbors: [UUID: [UUID]] = [:]
                for lot in context.lots {
                    guard let parent = lot.splitFromLotID else { continue }
                    neighbors[parent, default: []].append(lot.id)
                    neighbors[lot.id, default: []].append(parent)
                }
                var pending = Array(ids)
                while let id = pending.popLast() {
                    for peer in neighbors[id] ?? [] where ids.insert(peer).inserted { pending.append(peer) }
                }
            }
            lots = ids; sources = Set(context.lots.filter { ids.contains($0.id) }.map(\.source))
            let foods = Set(context.lots.filter { ids.contains($0.id) }.map(\.foodID))
            claims = Set(context.claims.filter { claim in
                selection == .wholeOrigin || (claim.lotID.map { ids.contains($0) } ?? (claim.state != .released && foods.contains(claim.foodID)))
            }.map(\.id))
        }
        func matches(_ value: Subject) -> Bool {
            if all { return true }
            switch value {
            case .lot(let id): return lots.contains(id)
            case .source(let value): return sources.contains(value)
            case .claim(let id): return claims.contains(id)
            case .journey(let id): return journey == id
            case .intent: return false
            }
        }
    }
    @MainActor private struct Collector {
        let context: Context
        let target: Target
        var matches: Set<Match> = []
        var sourceFacts: Set<UUID> = []
        var ledgerOrigins: Set<UUID> = []
        var unresolved: Set<Reason> = []
        mutating func add(_ value: Subject, _ role: Role) {
            if target.matches(value) { matches.insert(.init(subject: value, role: role)) }
        }
        mutating func lot(_ value: InventoryLot, _ role: Role) {
            guard value.source.originID == context.originID else { unresolved.insert(.foreignLineage); return }
            add(.lot(value.id), role); add(.source(value.source), role)
            if let parent = value.splitFromLotID { add(.lot(parent), .identityLink) }
        }
        mutating func portionLinks(_ change: InventoryChange) {
            if case let .create(seed, _) = change, let parent = seed.splitFromLotID { add(.lot(parent), .identityLink) }
            if case .revise(let edit) = change, case let .split(_, _, child, _, _) = edit.portion { add(.lot(child), .identityLink) }
        }
        mutating func claim(_ value: InventoryReservation, _ role: Role) {
            guard value.originID == context.originID else { unresolved.insert(.foreignLineage); return }
            add(.claim(value.id), role)
            if let id = value.lotID { add(.lot(id), role) }
        }
        mutating func source(_ value: InventorySource, _ role: Role) {
            guard value.originID == context.originID else { unresolved.insert(.foreignLineage); return }
            add(.source(value), role)
            if let id = context.sourceLots[value] {
                add(.lot(id), role)
                if role == .sourceFact { sourceFacts.insert(id) }
            }
        }
        mutating func legacyLot(_ id: UUID, _ role: Role) {
            guard let lots = context.aliases[id], lots.count == 1 else {
                unresolved.insert(.unresolvedLegacyLot)
                return
            }
            for canonical in lots { add(.lot(canonical), role) }
        }
        mutating func need(_ id: UUID, foodID: UUID, _ role: Role) throws {
            add(.claim(try PantryLegacyMigration.claimIdentity(originID: context.originID, needID: id, foodID: foodID)), role)
        }
        mutating func pack(_ selection: LedgerPackSelection) {
            ledgerOrigins.insert(selection.sourceWorkspaceID)
            if let proof = selection.canonicalStockEvidence {
                guard proof.basis.originID == context.originID else { unresolved.insert(.foreignLineage); return }
                for row in proof.lots { lot(row.lot, .incidentalCopy) }
                for row in proof.partition { if let value = row.reservation { claim(value, .incidentalCopy) }; if let id = row.binding.reservationID { add(.claim(id), .incidentalCopy) } }
                for head in proof.basis.sourceHeads { add(.journey(head.journeyID), .identityLink) }
            }
            if let proof = selection.stockEvidence {
                guard proof.sourceWorkspaceID == context.originID else { unresolved.insert(.foreignLineage); return }
                add(.journey(proof.journeyID), .incidentalCopy)
                for value in proof.lots { legacyLot(value.id, .incidentalCopy) }
                for pin in proof.reservations { legacyLot(pin.lotID, .incidentalCopy) }
            }
        }
        mutating func away(_ record: AwayCarryoverRecord) throws {
            try AwayCarryoverEngine.validate(record.intent)
            let intent = record.intent
            ledgerOrigins.insert(intent.workspaceID)
            add(.journey(intent.plan.link.sourceShopID), .identityLink)
            try need(intent.plan.link.reservationID, foodID: intent.sourceNeed.orderLineID, .incidentalCopy)
            try need(intent.sourceNeed.id, foodID: intent.sourceNeed.orderLineID, .incidentalCopy)
            switch intent.supply {
            case .batch(let value): source(.manual(originID: context.originID, sourceID: value.id), .incidentalCopy)
            case .received(let receipt, _): source(.receipt(originID: context.originID, key: receipt.key), .incidentalCopy)
            }
            if let proof = intent.canonical {
                lot(proof.lot, .incidentalCopy); claim(proof.sourceClaim, .incidentalCopy)
                for head in proof.basis.sourceHeads { add(.journey(head.journeyID), .identityLink) }
            }
        }
        mutating func journey(_ value: PickupJourney) throws {
            for record in value.cookedMeals ?? [] {
                guard record.draft.inventoryID == context.originID else { unresolved.insert(.foreignLineage); continue }
                ledgerOrigins.insert(record.draft.ledgerID)
                for part in record.draft.parts {
                    if case .lot(let id, _, _) = part.use { add(.lot(id), .incidentalCopy) }
                }
                for amendment in record.resolutions ?? [] {
                    if let id = amendment.decision.lotID { add(.lot(id), .incidentalCopy) }
                }
                for output in record.draft.leftovers {
                    add(.lot(output.id), .sourceFact)
                    sourceFacts.insert(output.id)
                }
                for claim in record.priorClaims { add(.claim(claim.id), .incidentalCopy) }
            }
            try PickupModel.validate(value)
            add(.journey(value.id), .sourceFact)
            if let ledger = value.mealSource?.ledgerWorkspaceID { ledgerOrigins.insert(ledger) }
            if let ancestor = value.originShopID { add(.journey(ancestor), .identityLink) }
            for lot in value.stockLots { source(.manual(originID: context.originID, sourceID: lot.id), .sourceFact) }
            for receipt in value.pickup?.receipts ?? [] { source(.receipt(originID: context.originID, key: receipt.key), .sourceFact) }
            for observation in value.pickup?.usableObservations ?? [] { source(.receipt(originID: context.originID, key: observation.receipt), .sourceFact) }
            for need in value.rawPhysicalStockNeeds { try self.need(need.id, foodID: need.foodID, .claim) }
            for need in value.carriedMeals { try self.need(need.id, foodID: need.orderLineID, .incidentalCopy) }
            for deferred in value.deferred { add(.journey(deferred.sourceShopID), .identityLink) }
            for urgent in value.urgent {
                if let ancestor = urgent.carriedFromID { add(.journey(ancestor), .identityLink) }
            }
            for selection in value.ledgerPackSelections { pack(selection) }
            for record in value.awayCarryovers { try away(record) }
            if let history = value.mealRecovery {
                ledgerOrigins.insert(history.source.ledgerWorkspaceID)
                var copiedNeeds = history.domain.outsideDemands + history.domain.originalMeals.flatMap(\.needs)
                for event in history.domain.contextChanges {
                    switch event.request.change {
                    case .appendOutside(let needs): copiedNeeds += needs
                    case let .transferCarryover(_, source, reservation): copiedNeeds += [source, reservation]
                    case .moveMeal, .confirmDeadline: break
                    }
                }
                for need in copiedNeeds { try self.need(need.id, foodID: need.foodID, .incidentalCopy) }
                for event in history.domain.events {
                    if let proof = event.canonicalAllocation {
                        guard proof.basis.originID == context.originID else { unresolved.insert(.foreignLineage); continue }
                        for value in proof.lots { lot(value, .incidentalCopy) }
                        for value in proof.claims { claim(value, .incidentalCopy) }
                        for binding in proof.bindings + proof.replacementBindings { add(.claim(binding.reservationID), .incidentalCopy) }
                        for head in proof.basis.sourceHeads { add(.journey(head.journeyID), .identityLink) }
                    }
                    for evidence in event.stockEvidence { legacyLot(evidence.lot.id, .incidentalCopy) }
                    for pin in event.reservations { legacyLot(pin.lotID, .incidentalCopy) }
                    for need in event.request.target.needs + event.request.replacement.needs { try self.need(need.id, foodID: need.foodID, .incidentalCopy) }
                }
            }
        }
        mutating func provenance(_ value: PantryMigrationPackage.Envelope) throws {
            guard value.originID == context.originID else { unresolved.insert(.foreignLineage); return }
            switch value.body {
            case .context(let value): if let id = value.ledgerOriginID { ledgerOrigins.insert(id) }
            case .sourceHead(let head): add(.journey(head.id), .identityLink)
            case .originalLot(let value, _): lot(value, .incidentalCopy)
            case .originalObservation(let value, _): add(.lot(value.lotID), .incidentalCopy)
            case let .sourceReference(id, reference):
                add(.lot(id), .identityLink); add(.journey(reference.journeyID), .identityLink)
            case .observationLink(let link, _): add(.lot(link.lotID), .identityLink); add(.journey(link.journeyID), .identityLink)
            case let .claimLink(id, _, journey): add(.claim(id), .identityLink); add(.journey(journey), .identityLink)
            case .pending(let value):
                add(.journey(value.journeyID), .identityLink); add(.claim(value.reservationID), .incidentalCopy)
                if let id = value.lotID { add(.lot(id), .incidentalCopy) }; try away(value.record)
            case .issue(let value):
                if let id = value.lotID { add(.lot(id), .identityLink) }; if let id = value.claimID { add(.claim(id), .identityLink) }
                for id in value.sourceIDs { add(.journey(id), .identityLink) }
            }
        }
    }

    /// One payload at a time. Unknown or malformed content becomes an explicit
    /// unresolved inspection rather than silently disappearing from the review.
    static func inspect(_ record: InventoryRecord, selection: Selection, context: Context) throws -> Inspection {
        try inspect(record, target: Target(selection, context: context), context: context)
    }
    private static func inspect(_ record: InventoryRecord, target: Target, context: Context) throws -> Inspection {
        var result = Collector(context: context, target: target)
        let container = Container.inventory(record.key, revision: record.revision)
        do {
            guard record.payloadVersion == 1, record.revision > 0, !record.payload.isEmpty,
                  record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidContext }
            try ArchiveCodec.preflight(record.payload, maximum: InventoryPersistenceLimits.recordBytes)
            switch record.key.kind {
            case .lot:
                let value = try PantryPersistenceCodec.lot(record); try knownFields(value, bytes: record.payload); result.lot(value, .physicalFact)
            case .observation:
                let value = try PantryPersistenceCodec.observation(record); try knownFields(value, bytes: record.payload); result.add(.lot(value.lotID), .physicalFact)
            case .reservation:
                let value = try PantryPersistenceCodec.reservation(record); try knownFields(value, bytes: record.payload); result.claim(value, .claim)
            case .sourceLink:
                let value = try PantryPersistenceCodec.sourceLink(record); try knownFields(value, bytes: record.payload)
                result.add(.lot(value.lotID), .physicalFact); result.source(value.source, .physicalFact)
            case .event:
                let value = try JSONDecoder().decode(InventoryEvent.self, from: record.payload)
                guard record.key.id == value.id, record.source == nil, record.lotID == value.lotID, record.revision == 1, value.originID == context.originID else { throw Failure.invalidContext }
                try PantryArchiveCodec.validateHistory(.originalEvent(value), at: context.at); try knownFields(value, bytes: record.payload)
                result.add(.lot(value.lotID), .physicalFact)
                result.portionLinks(value.change)
                if case .create(let seed, _) = value.change { result.source(seed.source, .physicalFact) }
            case .intent:
                guard let object = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any] else { throw Failure.invalidContext }
                if let namespace = object["namespace"] {
                    guard namespace as? String == "pantry-legacy-provenance/v1" else {
                        result.unresolved.insert(.unknownNamespace); return inspection(container, record.payload, result)
                    }
                    let decoded = try JSONDecoder().decode(PantryMigrationPackage.Envelope.self, from: record.payload)
                    let value = try PantryMigrationPackage.provenance(record, migrationID: decoded.migrationID, originID: context.originID)
                    try knownFields(value, bytes: record.payload); try result.provenance(value)
                } else if object["binding"] != nil {
                    let value = try PantryLedgerProjectionPort.archiveBinding(record); try knownFields(value, bytes: record.payload)
                    guard value.binding.inventoryWorkspaceID == context.originID else { throw Failure.invalidContext }
                    // Binding validates hashes and tuple, not the application-specific
                    // bytes in canonicalRequest. No production kind decoder exists yet.
                    result.ledgerOrigins.insert(value.binding.ledgerWorkspaceID)
                    result.add(.intent(record.key.id), .identityLink); result.unresolved.insert(.opaqueProjectionRequest)
                } else if object["decision"] != nil {
                    let value = try JSONDecoder().decode(PantryLedgerProjectionPort.ReviewDisposition.self, from: record.payload)
                    try knownFields(value, bytes: record.payload)
                    result.add(.intent(value.sourceIntentID), .identityLink); result.unresolved.insert(.unverifiedDisposition)
                } else { result.unresolved.insert(.unknownPayloadShape) }
            }
        } catch is UnknownFields { result.unresolved.insert(.unknownPayloadShape) }
        catch { result.unresolved.insert(.invalidPayload) }
        return inspection(container, record.payload, result)
    }

    static func inspect(_ saved: SavedComparison, selection: Selection, context: Context) throws -> Inspection {
        try inspectHead(.init(saved), container: .pickup(saved.id, revision: saved.revision), target: Target(selection, context: context), context: context)
    }
    private static func inspectHead(_ head: PantryLegacyMigration.SourceHead, container: Container,
                                    target: Target, context: Context) throws -> Inspection {
        var result = Collector(context: context, target: target)
        do {
            guard head.revision > 0, head.payload.count <= ComparisonStore.maximumPayloadBytes, head.savedAt <= context.at else { throw Failure.invalidContext }
            try ArchiveCodec.preflight(head.payload, maximum: ComparisonStore.maximumPayloadBytes)
            let value = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            guard value.id == head.id, value.savedAt == head.savedAt, value.version == 1 else { throw Failure.invalidContext }
            try knownFields(value, bytes: head.payload); try result.journey(value)
        } catch is UnknownFields { result.unresolved.insert(.unknownPayloadShape) }
        catch { result.unresolved.insert(.invalidPayload) }
        return inspection(container, head.payload, result)
    }

    /// The worker has already bounded and decoded a historical item. This hook
    /// inspects protected journals and archived copies without turning them into
    /// live commands. Foreign restored lineage remains explicitly unresolved.
    static func inspect(_ history: PantryArchiveCodec.History, identity: String,
                        selection: Selection, context: Context) throws -> Inspection {
        guard !identity.isEmpty, identity.utf8.count <= 512 else { throw Failure.invalidContext }
        var result = Collector(context: context, target: try Target(selection, context: context))
        let bytes = try ArchiveCodec.canonical(history)
        guard bytes.count <= PantryArchiveCodec.maximumChunkBytes else { throw Failure.capacity }
        do {
            try PantryArchiveCodec.validateHistory(history, at: context.at)
            switch history {
            case .migration(let value): try result.provenance(value)
            case let .sourceHead(origin, head):
                if origin != context.originID { result.unresolved.insert(.foreignLineage) }
                else {
                    let copy = try inspectHead(head, container: .external(identity), target: result.target, context: context)
                    result.matches.formUnion(copy.matches.map { .init(subject: $0.subject, role: .incidentalCopy) })
                    result.unresolved.formUnion(copy.unresolved)
                }
            case .price(let origin, let price):
                guard origin == context.originID else { result.unresolved.insert(.foreignLineage); break }
                if let id = price.linkedLotID { result.add(.lot(id), .incidentalCopy) }
            case .acquisition(let origin, let row):
                guard origin == context.originID else { result.unresolved.insert(.foreignLineage); break }
                result.add(.lot(row.lotID), .incidentalCopy)
                if let pickup = row.savedPickup, pickup.originID == context.originID { result.add(.journey(pickup.id), .incidentalCopy) }
                if case .linked(let fragment) = row.stock { result.source(.receipt(originID: origin, key: fragment), .incidentalCopy) }
            case .originalLot(let value): result.lot(value, .incidentalCopy)
            case .originalObservation(let origin, let value):
                if origin != context.originID { result.unresolved.insert(.foreignLineage) } else { result.add(.lot(value.lotID), .incidentalCopy) }
            case .originalEvent(let value):
                guard value.originID == context.originID else { result.unresolved.insert(.foreignLineage); break }
                result.add(.lot(value.lotID), .incidentalCopy)
                result.portionLinks(value.change)
                if case .create(let seed, _) = value.change { result.source(seed.source, .incidentalCopy) }
            case .originalReservation(let value): result.claim(value, .incidentalCopy)
            case .originalSourceLink(let value): result.source(value.source, .incidentalCopy); result.add(.lot(value.lotID), .incidentalCopy)
            case .foodPending(let value):
                guard value.command.originID == context.originID else { result.unresolved.insert(.foreignLineage); break }
                for command in value.commands {
                    result.add(.lot(command.lotID), .incidentalCopy)
                    if case .reservation(let edit) = command.change { result.add(.claim(edit.id), .incidentalCopy) }
                    result.portionLinks(command.change)
                    if case .create(let seed, _) = command.change { result.source(seed.source, .incidentalCopy) }
                }
            case .packPending(let value):
                if value.request.inventoryWorkspaceID != context.originID { result.unresolved.insert(.foreignLineage) } else { result.pack(value.request.selection) }
            case .pickupPending(let value):
                guard value.submission.request.originID == context.originID else { result.unresolved.insert(.foreignLineage); break }
                for head in value.submission.changedHeads {
                    let inspection = try inspectHead(head, container: .external(identity), target: result.target, context: context)
                    result.matches.formUnion(inspection.matches.map { .init(subject: $0.subject, role: .incidentalCopy) })
                    result.unresolved.formUnion(inspection.unresolved)
                }
            case .projection: result.unresolved.insert(.opaqueProjectionRequest)
            case .restoredFrom: result.unresolved.insert(.foreignLineage)
            }
        } catch { result.unresolved.insert(.invalidPayload) }
        return inspection(.external(identity), bytes, result)
    }

    /// Reads every retained SQL revision at one exact basis, retaining only matched
    /// metadata. The caller owns its shared gate and fresh private authorization.
    static func scan(store: ComparisonStore, selection: Selection, context: Context,
                     authorize: () -> Bool) async throws -> Preview {
        guard store.workspaceID == context.originID else { throw Failure.invalidContext }
        var target = try Target(selection, context: context)
        if let selected = target.journey {
            // A receipt may have disappeared from the latest journey. Identify
            // its direct carriers before looking for copies in other histories.
            var sourceLots = Set<UUID>()
            var cursor: InventoryComparisonRevisionCursor?
            while true {
                try Task.checkCancellation()
                guard authorize() else { throw Failure.unauthorized }
                let page = try await store.inventoryComparisonRevisionPage(expectedRevision: context.inventoryRevision,
                    sourceToken: context.sourceToken, after: cursor)
                guard authorize() else { throw Failure.unauthorized }
                guard let last = page.last else { break }
                for saved in page where saved.id == selected {
                    let value = try inspectHead(.init(saved), container: .pickup(selected, revision: saved.revision),
                        target: target, context: context)
                    sourceLots.formUnion(value.sourceFactLotIDs)
                }
                cursor = .init(id: last.id, revision: last.revision)
            }
            target = try Target(selection, context: context, historicalSourceLots: sourceLots)
        }
        var inspections: [Inspection] = []
        var retainedEdges = 0
        var ledgerOrigins = Set<UUID>()
        func retain(_ value: Inspection) throws {
            ledgerOrigins.formUnion(value.ledgerOrigins)
            guard ledgerOrigins.count <= 10_000 else { throw Failure.capacity }
            if !value.matches.isEmpty || !value.unresolved.isEmpty || selection == .wholeOrigin {
                retainedEdges += value.matches.count + value.sourceFactLotIDs.count
                guard inspections.count < 250_000, retainedEdges <= 500_000 else { throw Failure.capacity }
                inspections.append(value)
            }
        }
        var cursor: InventoryRevisionCursor?
        while true {
            guard authorize() else { throw Failure.unauthorized }
            let page = try await store.inventoryRevisionPage(expectedRevision: context.inventoryRevision, sourceToken: context.sourceToken, after: cursor)
            guard authorize() else { throw Failure.unauthorized }
            if page.isEmpty { break }
            for row in page { try Task.checkCancellation(); try retain(inspect(row, target: target, context: context)) }
            if let last = page.last { cursor = .init(kind: last.key.kind, id: last.key.id, revision: last.revision) }
        }
        var sourceCursor: InventoryComparisonRevisionCursor?
        while true {
            guard authorize() else { throw Failure.unauthorized }
            let page = try await store.inventoryComparisonRevisionPage(expectedRevision: context.inventoryRevision, sourceToken: context.sourceToken, after: sourceCursor)
            guard authorize() else { throw Failure.unauthorized }
            if page.isEmpty { break }
            for row in page {
                try Task.checkCancellation()
                try retain(inspectHead(.init(row), container: .pickup(row.id, revision: row.revision), target: target, context: context))
            }
            if let last = page.last { sourceCursor = .init(id: last.id, revision: last.revision) }
        }
        // The supplied mapper plan must cover the exact live heads. A valid
        // token paired with an older or partial mapper plan cannot verify scope.
        var expectedHeads = Dictionary(uniqueKeysWithValues: context.mapping.sourceHeads.map { ($0.id, $0) })
        var headCursor: UUID?
        while true {
            try Task.checkCancellation()
            guard authorize() else { throw Failure.unauthorized }
            let page = try await store.inventorySourcePage(token: context.sourceToken, after: headCursor, limit: 4)
            guard authorize() else { throw Failure.unauthorized }
            guard let last = page.last else { break }
            for saved in page {
                guard expectedHeads.removeValue(forKey: saved.id) == PantryLegacyMigration.SourceHead(saved) else { throw Failure.stale }
            }
            headCursor = last.id
        }
        guard expectedHeads.isEmpty else { throw Failure.stale }
        let state = try await store.inventoryState(); guard authorize() else { throw Failure.unauthorized }
        let token = try await store.inventorySourceToken(); guard authorize() else { throw Failure.unauthorized }
        guard state.revision == context.inventoryRevision, token == context.sourceToken else { throw Failure.stale }
        return try preview(selection: selection, target: target, context: context, inspections: inspections, ledgerOrigins: ledgerOrigins)
    }

    private static func preview(selection: Selection, target: Target, context: Context, inspections: [Inspection], ledgerOrigins: Set<UUID>) throws -> Preview {
        guard inspections.count <= 250_000 else { throw Failure.capacity }
        let explicit: Set<UUID>
        switch selection { case .lot: explicit = target.lots; case .wholeOrigin: explicit = Set(context.lots.map(\.id)); case .pickup, .price: explicit = [] }
        let collateral = Set(inspections.compactMap { value -> UUID? in
            guard case .pickup(let id, _) = value.container, value.containsPrivateDependency, target.journey != id else { return nil }; return id
        })
        let retained = Set(context.lots.map(\.id)).subtracting(explicit)
        let receiptLots = Set(context.lots.compactMap { lot -> UUID? in
            guard case .receipt = lot.source, retained.contains(lot.id) else { return nil }
            return lot.id
        })
        let liveCollateralReceipts = Set(context.mapping.sourceLinks.compactMap { link -> UUID? in
            guard receiptLots.contains(link.lotID), link.references.contains(where: { collateral.contains($0.journeyID) }) else { return nil }
            return link.lotID
        })
        let collateralReceiptLots = inspections.reduce(into: liveCollateralReceipts) { ids, row in
            guard case .pickup(let id, _) = row.container, collateral.contains(id) else { return }
            ids.formUnion(row.sourceFactLotIDs.intersection(receiptLots))
        }
        let erasedClaims = selection == .wholeOrigin ? Set(context.claims.map(\.id)) : []
        let review = try InventoryPrivacyErasure.review(originID: context.originID, lots: context.lots,
            reservations: context.claims, erasingLots: explicit, erasingReservations: erasedClaims, at: context.at)
        return .init(selection: selection, originID: context.originID, inventoryRevision: context.inventoryRevision,
            sourceToken: context.sourceToken, inspections: inspections, explicitlySelectedLotIDs: explicit, ledgerOrigins: ledgerOrigins,
            retainedPhysicalLotIDs: retained,
            pickupSourceCandidateLotIDs: target.journey == nil ? [] : target.lots,
            collateralPickupIDs: selection == .wholeOrigin ? [] : collateral,
            sqlHistoriesComplete: true, remainingScopes: [.externalCopiesNotScanned],
            retainedReceiptLotIDsInCollateralPickups: collateralReceiptLots, retainedReservations: review.remainingReservations)
    }
    private static func inspection(_ container: Container, _ bytes: Data, _ value: Collector) -> Inspection {
        .init(container: container, payloadDigest: Data(SHA256.hash(data: bytes)), matches: value.matches,
            sourceFactLotIDs: value.sourceFacts, unresolved: value.unresolved, ledgerOrigins: value.ledgerOrigins)
    }
    private struct UnknownFields: Error {}
    /// Accept missing old optional fields, but never discard unknown private data.
    /// This is structural checking, not a name/string search for dependencies.
    nonisolated static func knownFields<T: Encodable>(_ value: T, bytes: Data) throws {
        let old = try JSONSerialization.jsonObject(with: bytes), known = try JSONSerialization.jsonObject(with: ArchiveCodec.canonical(value))
        func check(_ old: Any, _ known: Any, depth: Int) throws {
            guard depth <= 128 else { throw UnknownFields() }
            if let object = old as? [String: Any] {
                guard let counterpart = known as? [String: Any] else { throw UnknownFields() }
                for (key, value) in object {
                    guard let recognized = counterpart[key] else { throw UnknownFields() }
                    try check(value, recognized, depth: depth + 1)
                }
            } else if let rows = old as? [Any] {
                guard let counterparts = known as? [Any], rows.count == counterparts.count else { throw UnknownFields() }
                for (left, right) in zip(rows, counterparts) { try check(left, right, depth: depth + 1) }
            }
        }
        try check(old, known, depth: 0)
    }
}
