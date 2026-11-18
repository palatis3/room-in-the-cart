import CoreDomain
import Foundation
import LocalStore
import RecordArchive

/// Admission is determined only by this device's durable erasures. Archive evidence
/// can describe a historical origin, but can never retire a local record.
@MainActor enum PantryArchivePrivacyValidator {
    enum Failure: Error, Equatable { case retired, unverifiable, unauthorized, stale }

    static func validate(_ handle: PantryArchiveHandle, worker: PantryArchiveWorker,
                         inventory: ComparisonStore, ledger: LedgerStore, gate: PantryMutationGate,
                         retiredOrigins: Set<UUID> = [], authorize: @escaping RecordsToolsModel.Authorization) async throws {
        try await withLocalRules(inventory: inventory, ledger: ledger, gate: gate, retiredOrigins: retiredOrigins, authorize: authorize) { rules in
            try await rules.check(handle, worker: worker)
        }
    }

    static func validate(_ record: ArchiveRecord, inventory: ComparisonStore, ledger: LedgerStore, gate: PantryMutationGate,
                         retiredOrigins: Set<UUID> = [], authorize: @escaping RecordsToolsModel.Authorization) async throws {
        guard record.kind == .pickup || record.kind == .ledger else { return }
        try await withLocalRules(inventory: inventory, ledger: ledger, gate: gate, retiredOrigins: retiredOrigins, authorize: authorize) { rules in
            try rules.check(record, pairedLedgerOrigin: ledger.workspaceID)
        }
    }

    private static func withLocalRules(inventory: ComparisonStore, ledger: LedgerStore, gate: PantryMutationGate,
                                       retiredOrigins: Set<UUID>, authorize: @escaping RecordsToolsModel.Authorization,
                                       check: (LocalRules) async throws -> Void) async throws {
        func access() throws {
            try Task.checkCancellation()
            guard authorize() else { throw Failure.unauthorized }
        }
        try access()
        let lease = try gate.beginExclusiveWrite()
        defer { gate.endExclusiveWrite(lease) }

        let retirement = try await inventory.inventoryOriginRetirement()
        try access()
        var rules = LocalRules(origin: inventory.workspaceID, retiredOrigin: retirement != nil)
        rules.retiredInventoryOrigins = retiredOrigins
        var state: InventoryState?
        var token: InventorySourceToken?
        if retirement == nil {
            let initial = try await inventory.inventoryState()
            try access()
            let initialToken = try await inventory.inventorySourceToken()
            try access()
            state = initial
            token = initialToken
            var priceCursor: UUID?
            repeat {
                let page = try await inventory.retiredPriceIDs(after: priceCursor, limit: 100)
                try access()
                rules.prices.formUnion(page)
                priceCursor = page.count == 100 ? page.last : nil
            } while priceCursor != nil
            for kind in InventoryRecordKind.allCases {
                var cursor: UUID?
                repeat {
                    let page = try await inventory.inventoryTombstones(kind: kind, expectedInventoryRevision: initial.revision,
                                                                      after: cursor, limit: 200)
                    try access()
                    rules.keys.formUnion(page.map(\.key))
                    cursor = page.count == 200 ? page.last?.key.id : nil
                } while cursor != nil
            }
            var sourceCursor: InventorySourceIdentity?
            repeat {
                let page = try await inventory.inventoryRetiredSources(expectedInventoryRevision: initial.revision, after: sourceCursor, limit: 200)
                try access()
                for value in page { rules.sources[value.source.originID, default: []].insert(value.source.sourceID) }
                sourceCursor = page.count == 200 ? page.last?.source : nil
            } while sourceCursor != nil
            var cursor: UUID?
            repeat {
                let page = try await inventory.inventoryReservationRedactions(expectedInventoryRevision: initial.revision, after: cursor, limit: 200)
                try access()
                for value in page { rules.floors[value.reservationID] = value.throughRevision }
                cursor = page.count == 200 ? page.last?.reservationID : nil
            } while cursor != nil
            repeat {
                let page = try await inventory.inventoryComparisonTombstones(token: initialToken, after: cursor, limit: 200)
                try access()
                rules.comparisons.formUnion(page.map(\.id))
                cursor = page.count == 200 ? page.last?.id : nil
            } while cursor != nil
        }

        let ledgerRevision = try await ledger.load()?.revision ?? 0
        try access()
        var ledgerCursor: UUID?
        repeat {
            let page = try await ledger.tombstonePage(expectedWorkspaceID: ledger.workspaceID, expectedRevision: ledgerRevision,
                                                      after: ledgerCursor, limit: 200)
            try access()
            rules.ledgers.formUnion(page.map(\.workspaceID))
            ledgerCursor = page.count == 200 ? page.last?.workspaceID : nil
        } while ledgerCursor != nil

        try await check(rules)
        try access()

        // Non-cooperating SQLite connections do not hold the app gate.
        guard try await inventory.inventoryOriginRetirement() == retirement else { throw Failure.stale }
        try access()
        if let state, let token {
            guard try await inventory.inventoryState() == state else { throw Failure.stale }
            try access()
            guard try await inventory.inventorySourceToken() == token else { throw Failure.stale }
            try access()
        }
        _ = try await ledger.tombstonePage(expectedWorkspaceID: ledger.workspaceID, expectedRevision: ledgerRevision, limit: 1)
        try access()
    }

    struct LocalRules: Sendable {
        let origin: UUID
        let retiredOrigin: Bool
        var keys = Set<InventoryRecordKey>()
        var prices = Set<UUID>()
        var sources = [UUID: Set<String>]()
        var floors = [UUID: Int64]()
        var comparisons = Set<UUID>()
        var ledgers = Set<UUID>()
        var retiredInventoryOrigins = Set<UUID>()

        /// Shared by restore admission and read-only inspection of a proposed
        /// erasure. A match is reported only after the whole bundle authenticates.
        @MainActor func check(_ record: ArchiveRecord, pairedLedgerOrigin: UUID) throws {
            guard hasErasures, record.kind == .pickup || record.kind == .ledger else { return }
            let components = record.origin.split(separator: "/", omittingEmptySubsequences: false)
            let expected = record.kind == .pickup ? "pickups" : "ledger"
            guard components.count == 2, components[0] == expected, let namespace = UUID(uuidString: String(components[1])) else {
                throw Failure.unverifiable
            }
            if record.kind == .pickup {
                try checkOrigin(namespace)
                guard let id = UUID(uuidString: record.id) else { throw Failure.unverifiable }
                try journeyID(id, namespace)
                guard let payload = record.nativePayload else { return }
                let value = try RecordsNativeCodec.pickup(payload)
                guard value.id == id else { throw Failure.unverifiable }
                try journey(.init(id: id, revision: 1, payload: payload, savedAt: value.savedAt), namespace)
            } else {
                try ledger(namespace)
                guard let payload = record.nativePayload else { return }
                let workspace = try RecordsNativeCodec.ledger(payload)
                for selection in workspace.packSelections {
                    if let inventory = selection.canonicalStockEvidence?.basis.originID ?? selection.stockEvidence?.sourceWorkspaceID {
                        try pack(selection, inventory)
                    }
                }
                for carryover in workspace.shops.flatMap(\.mealOccurrences).compactMap(\.carryover) {
                    // Legacy carryovers omit their physical origin. A rotated or
                    // independently restored ledger cannot prove which pantry supplied it.
                    guard namespace == pairedLedgerOrigin, retiredInventoryOrigins.isEmpty else { throw Failure.unverifiable }
                    try journeyID(carryover.sourceShopID, origin)
                    try legacyLot(carryover.sourceSupplyID, origin)
                    try legacyLot(carryover.confirmedSupplyID, origin)
                    try key(.reservation, carryover.reservationID, origin)
                    if sources[origin] != nil { throw Failure.unverifiable }
                }
            }
        }
        func check(_ handle: PantryArchiveHandle, worker: PantryArchiveWorker) async throws {
            try await worker.inspectContent(handle, item: { item in
                try check(item, origin: handle.descriptor.originID)
            }, evidence: { value in
                switch value {
                case .previousScope(let scope): try check(scope)
                case .historical(let origin, let value): try checkOrigin(origin); try evidenceOrigins(value)
                case .current(let value): try evidenceOrigins(value)
                }
            })
            try check(handle.scope)
        }

        private func evidenceOrigins(_ evidence: PantryArchiveCapture.Evidence) throws {
            switch evidence {
            case .inventoryRetired(_, let origin, _, _), .comparisonRetired(_, let origin, _, _, _):
                try checkOrigin(origin)
            case .sourceRetired(let source, let origin, _):
                try checkOrigin(origin); try checkOrigin(source.originID)
            case .reservationRedacted(let value): try checkOrigin(value.workspaceID)
            case .ledgerRetired, .projection: break
            }
        }
        var hasErasures: Bool {
            retiredOrigin || !retiredInventoryOrigins.isEmpty || !prices.isEmpty || !keys.isEmpty || !sources.isEmpty || !floors.isEmpty || !comparisons.isEmpty || !ledgers.isEmpty
        }
        func checkOrigin(_ id: UUID) throws {
            if (retiredOrigin && origin == id) || retiredInventoryOrigins.contains(id) { throw Failure.retired }
        }
        func ledger(_ id: UUID?) throws {
            if let id, ledgers.contains(id) { throw Failure.retired }
        }
        func key(_ kind: InventoryRecordKind, _ id: UUID?, _ namespace: UUID) throws {
            try checkOrigin(namespace)
            if namespace == origin, let id, keys.contains(.init(kind, id)) { throw Failure.retired }
        }
        func journeyID(_ id: UUID?, _ namespace: UUID) throws {
            try checkOrigin(namespace)
            if namespace == origin, let id, comparisons.contains(id) { throw Failure.retired }
        }
        func source(_ value: InventorySource) throws {
            try checkOrigin(value.originID)
            if let retired = sources[value.originID], try retired.contains(PantryPersistenceCodec.sourceIdentity(value).sourceID) {
                throw Failure.retired
            }
        }
        func check(_ scope: PantryArchiveWorker.Scope) throws {
            try checkOrigin(scope.originID)
            switch scope {
            case .independent(let copy): try checkOrigin(copy.originalOriginID)
            case .paired(let pair): try ledger(pair.ledgerOriginID)
            }
        }
        func lot(_ value: InventoryLot) throws {
            try key(.lot, value.id, value.source.originID)
            try key(.observation, value.observationID, value.source.originID)
            try source(value.source)
        }
        func observation(_ value: InventoryObservation, _ namespace: UUID) throws {
            try key(.observation, value.id, namespace)
            try key(.observation, value.supersedesID, namespace)
            try key(.lot, value.lotID, namespace)
        }
        func reservation(_ value: InventoryReservation) throws {
            try key(.reservation, value.id, value.originID)
            try key(.lot, value.lotID, value.originID)
            if value.originID == origin, let floor = floors[value.id], value.revision <= floor { throw Failure.retired }
        }
        func link(_ value: PantryPersistenceCodec.SourceLink) throws {
            try key(.sourceLink, value.lotID, value.source.originID)
            try key(.lot, value.lotID, value.source.originID)
            try source(value.source)
        }
        func change(_ value: InventoryChange, lot: UUID, event: UUID, origin: UUID) throws {
            try key(.lot, lot, origin)
            if case let .reservation(edit) = value {
                try key(.reservation, edit.id, origin)
                if origin == self.origin, let floor = floors[edit.id], max(1, edit.previousRevision) <= floor { throw Failure.retired }
                return
            }
            try key(.event, event, origin)
            switch value {
            case let .create(seed, id): try source(seed.source); try key(.observation, id, origin)
            case .count(_, let id), .usedUp(let id): try key(.observation, id, origin)
            case .revise(let update): try key(.observation, update.observation?.observationID, origin)
            case .move, .opened, .reservation: break
            }
        }
        func check(_ item: PantryArchiveCodec.Item, origin: UUID) throws {
            switch item {
            case .lot(let value): try lot(value)
            case .reservation(let value): try reservation(value)
            case .observation(let value): try observation(value, origin)
            case .sourceLink(let value): try link(value)
            case .event(let value): try change(value.change, lot: value.lotID, event: value.id, origin: value.originID)
            case .historical(let history): try check(history)
            }
        }
        func check(_ history: PantryArchiveCodec.History) throws {
            switch history {
            case .price(let namespace, let price):
                try checkOrigin(namespace)
                if namespace == origin {
                    if prices.contains(price.id) { throw Failure.retired }
                    if case .adjustment(let target, _, _) = price.source, prices.contains(target) { throw Failure.retired }
                }
                if let lot = price.linkedLotID { try key(.lot, lot, namespace) }
            case .acquisition(let origin, let row):
                try key(.lot, row.lotID, origin)
                if let pickup = row.savedPickup { try journeyID(pickup.id, pickup.originID) }
                if case .linked(let fragment) = row.stock { try source(.receipt(originID: origin, key: fragment)) }
            case .originalLot(let value): try lot(value)
            case .originalObservation(let origin, let value): try observation(value, origin)
            case .originalEvent(let value): try change(value.change, lot: value.lotID, event: value.id, origin: value.originID)
            case .originalReservation(let value): try reservation(value)
            case .originalSourceLink(let value): try link(value)
            case .restoredFrom(let value): try checkOrigin(value.originID)
            case .migration(let value): try migration(value)
            case .sourceHead(let origin, let head): try journey(head, origin)
            case .foodPending(let entry):
                let command = entry.command
                try change(command.change, lot: command.lotID, event: command.eventID, origin: command.originID)
            case .packPending(let entry):
                let request = entry.request
                try checkOrigin(request.inventoryWorkspaceID)
                try ledger(request.ledgerWorkspaceID)
                if let basis = request.grossBasis {
                    try checkOrigin(basis.originID)
                    for head in basis.sourceHeads { try journeyID(head.journeyID, basis.originID) }
                }
                try pack(request.selection, request.inventoryWorkspaceID)
            case .pickupPending(let entry):
                let request = entry.submission.request
                try checkOrigin(request.originID)
                try ledger(request.ledgerOriginID)
                if case .select(let id) = entry.selection { try journeyID(id, request.originID) }
                for head in entry.submission.changedHeads { try journey(head, request.originID) }
            case .projection(let projection):
                let binding = projection.binding.binding
                try key(.intent, projection.sourceIntentID, binding.inventoryWorkspaceID)
                try key(.intent, projection.needsReview?.recordID, binding.inventoryWorkspaceID)
                try ledger(binding.ledgerWorkspaceID)
                // The binding authenticates opaque request bytes, but cannot attest
                // which pantry/ledger bodies those bytes contain.
                if hasErasures { throw Failure.unverifiable }
            }
        }

        func migration(_ value: PantryMigrationPackage.Envelope) throws {
            let ns = value.originID
            try key(.intent, value.id, ns)
            switch value.body {
            case .context(let context): try ledger(context.ledgerOriginID)
            case .sourceHead(let head): try journeyID(head.id, ns)
            case let .originalLot(original, baseline): try lot(original); try key(.observation, baseline, ns)
            case let .originalObservation(original, baseline): try observation(original, ns); try key(.observation, baseline, ns)
            case let .sourceReference(lot, ref):
                try key(.lot, lot, ns)
                try journeyID(ref.journeyID, ns)
                if let id = ref.legacyLotID { try legacyLot(id, ns) }
                if let receipt = ref.receiptKey { try source(.receipt(originID: ns, key: receipt)) }
                for id in ref.observationIDs { try key(.observation, id, ns) }
            case let .observationLink(ref, baseline):
                try key(.lot, ref.lotID, ns)
                for id in [ref.observationID, ref.legacyObservationID, baseline] { try key(.observation, id, ns) }
                try journeyID(ref.journeyID, ns)
            case let .claimLink(id, _, journey): try key(.reservation, id, ns); try journeyID(journey, ns)
            case .pending(let pending):
                try key(.lot, pending.lotID, ns)
                try key(.reservation, pending.reservationID, ns)
                try journeyID(pending.journeyID, ns)
                try away(pending.record, ns)
            case .issue(let issue):
                try key(.lot, issue.lotID, ns)
                try key(.reservation, issue.claimID, ns)
                for id in issue.sourceIDs { try journeyID(id, ns) }
            }
        }
        func legacyLot(_ id: UUID, _ ns: UUID) throws {
            try key(.lot, id, ns)
            try key(.observation, id, ns)
            try source(.manual(originID: ns, sourceID: id))
        }
        func need(_ id: UUID, _ food: UUID, _ ns: UUID) throws {
            guard ns == origin, !keys.isEmpty || !floors.isEmpty else { return }
            let claim = try PantryLegacyMigration.claimIdentity(originID: ns, needID: id, foodID: food)
            try key(.reservation, claim, ns)
            // A legacy need carries the original promise body without a canonical revision.
            if floors[claim] != nil { throw Failure.unverifiable }
        }
        func basis(_ value: LedgerCanonicalPackStockEvidence.Basis) throws {
            try checkOrigin(value.originID)
            for head in value.sourceHeads { try journeyID(head.journeyID, value.originID) }
        }
        /// Unlike the directly stored manual stock rows, a legacy allocation
        /// snapshot can identify a receipt only by its usable-observation UUID.
        /// Without a source carrier, a retired receipt cannot be excluded.
        func copiedLegacyLot(_ id: UUID, _ ns: UUID, carriers: Set<UUID>) throws {
            try legacyLot(id, ns)
            if sources[ns] != nil && !carriers.contains(id) { throw Failure.unverifiable }
        }
        func pack(_ selection: LedgerPackSelection, _ ns: UUID, carriers: Set<UUID> = []) throws {
            try journeyID(selection.shopID, ns)
            if let proof = selection.canonicalStockEvidence {
                try basis(proof.basis)
                for row in proof.lots { try lot(row.lot) }
                for row in proof.partition {
                    try key(.reservation, row.binding.reservationID, proof.basis.originID)
                    if let body = row.reservation { try reservation(body) }
                }
            }
            if let proof = selection.stockEvidence {
                let proven = proof.sourceWorkspaceID == ns ? carriers : []
                let ns = proof.sourceWorkspaceID
                try journeyID(proof.journeyID, ns)
                for row in proof.lots { try copiedLegacyLot(row.id, ns, carriers: proven) }
                for pin in proof.reservations { try copiedLegacyLot(pin.lotID, ns, carriers: proven) }
                for row in proof.needs { try need(row.id, row.foodID, ns) }
            }
        }
        func away(_ record: AwayCarryoverRecord, _ ns: UUID) throws {
            let intent = record.intent
            try ledger(intent.workspaceID)
            try journeyID(intent.plan.link.sourceShopID, ns)
            try key(.reservation, intent.plan.link.reservationID, ns)
            switch intent.supply {
            case .batch(let value): try legacyLot(value.id, ns)
            case .received(let receipt, let observation):
                try source(.receipt(originID: ns, key: receipt.key))
                try key(.observation, observation.id, ns)
            }
            if let proof = intent.canonical {
                try basis(proof.basis)
                try lot(proof.lot)
                try reservation(proof.sourceClaim)
            }
        }
        func journey(_ head: PantryLegacyMigration.SourceHead, _ ns: UUID) throws {
            try journeyID(head.id, ns)
            guard hasErasures else { return }
            let value = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            try PantryErasureDependencies.knownFields(value, bytes: head.payload)
            try journeyID(value.originShopID, ns)
            for row in value.deferred { try journeyID(row.sourceShopID, ns) }
            for row in value.urgent {
                try journeyID(row.carriedFromID, ns)
                try need(row.id, row.id, ns)
                try legacyLot(row.id, ns)
            }
            for row in value.carriedMeals { try need(row.id, row.orderLineID, ns) }
            for record in value.cookedMeals ?? [] {
                try ledger(record.draft.ledgerID)
                for row in record.priorCounts {
                    try key(.lot, row.lotID, record.draft.inventoryID)
                    try key(.observation, row.observationID, record.draft.inventoryID)
                }
                for (lotID, observationID) in record.resultingObservations {
                    try key(.lot, lotID, record.draft.inventoryID)
                    try key(.observation, observationID, record.draft.inventoryID)
                }
                if let undo = record.undo {
                    for id in undo.observations.values { try key(.observation, id, record.draft.inventoryID) }
                }
                for amendment in record.resolutions ?? [] {
                    try key(.lot, amendment.decision.lotID, record.draft.inventoryID)
                    try key(.observation, amendment.basis?.observationID, record.draft.inventoryID)
                    try key(.observation, amendment.resultObservationID, record.draft.inventoryID)
                }
                for claim in record.priorClaims { try key(.reservation, claim.id, record.draft.inventoryID) }
            }
            for row in value.stockLots { try legacyLot(row.id, ns) }
            for row in value.pickup?.receipts ?? [] { try source(.receipt(originID: ns, key: row.key)) }
            for row in value.pickup?.usableObservations ?? [] {
                try source(.receipt(originID: ns, key: row.receipt))
                try key(.observation, row.id, ns)
                try key(.observation, row.supersedesID, ns)
            }
            for row in value.rawPhysicalStockNeeds { try need(row.id, row.foodID, ns) }
            try ledger(value.mealSource?.ledgerWorkspaceID)
            let carriers = Set(value.stockLots.map(\.id)).union((value.pickup?.usableObservations ?? []).map(\.id))
            for selection in value.ledgerPackSelections { try pack(selection, ns, carriers: carriers) }
            for record in value.awayCarryovers { try away(record, ns) }
            if let history = value.mealRecovery {
                try ledger(history.source.ledgerWorkspaceID)
                for meal in history.domain.originalMeals {
                    for row in meal.needs { try need(row.id, row.foodID, ns) }
                }
                for row in history.domain.outsideDemands { try need(row.id, row.foodID, ns) }
                for event in history.domain.contextChanges {
                    switch event.request.change {
                    case .appendOutside(let rows):
                        for row in rows { try need(row.id, row.foodID, ns) }
                    case let .transferCarryover(_, old, new):
                        try need(old.id, old.foodID, ns)
                        try need(new.id, new.foodID, ns)
                    case .moveMeal, .confirmDeadline: break
                    }
                }
                for event in history.domain.events {
                    for row in event.request.target.needs + event.request.replacement.needs { try need(row.id, row.foodID, ns) }
                    for row in event.stockEvidence { try copiedLegacyLot(row.lot.id, ns, carriers: carriers) }
                    for pin in event.reservations { try copiedLegacyLot(pin.lotID, ns, carriers: carriers) }
                    if let proof = event.canonicalAllocation {
                        try basis(proof.basis)
                        for row in proof.lots { try lot(row) }
                        for row in proof.claims { try reservation(row) }
                        for row in proof.bindings + proof.replacementBindings { try key(.reservation, row.reservationID, proof.basis.originID) }
                    }
                }
            }
        }
    }
}
