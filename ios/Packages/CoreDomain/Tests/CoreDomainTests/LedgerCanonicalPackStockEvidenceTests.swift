import XCTest
@testable import CoreDomain

final class LedgerCanonicalPackStockEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private typealias Evidence = LedgerCanonicalPackStockEvidence
    private struct Fixture {
        let shop: ShoppingLedger
        let line: UUID
        let ledgerID: UUID
        let basis: Evidence.Basis
        let scope: Evidence.Scope
        let bindings: [Evidence.ClaimBinding]
        let lots: [InventoryLot]
        let claims: [InventoryReservation]
        let eligibility: [Evidence.LotEligibility]
        let basket: BasketPlan
    }
    private func fixture(otherProtected: Bool = false, count: InventoryCount? = nil, receipt: Bool = false) throws -> Fixture {
        var shop = ShoppingLedger()
        let line = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let supply = try XCTUnwrap(shop.contributions(forLineID: line).first?.id)
        try shop.addProtectedNeed(name: "Wraps", quantity: q(4), purpose: "Lunch", within: supply)
        let origin = UUID(), lotID = UUID(), observation = UUID()
        let required = StockNeed(id: UUID(), foodID: line, name: "Dinner", amount: q(8), priority: .required)
        let protected = StockNeed(id: UUID(), foodID: line, name: "Lunch", amount: q(4), priority: .protected)
        let requiredID = UUID(), protectedID = UUID()
        var claims = [InventoryReservation(id: requiredID, originID: origin, revision: 1, foodID: line,
            lotID: nil, name: required.name, amount: required.amount),
            InventoryReservation(id: protectedID, originID: origin, revision: 1, foodID: line,
                lotID: nil, name: protected.name, amount: protected.amount, priority: .protected)]
        if otherProtected {
            claims.append(.init(id: UUID(), originID: origin, revision: 1, foodID: line, lotID: lotID,
                name: "Other shop protected food", amount: q(8), priority: .protected))
        }
        let source: InventorySource = receipt
            ? .receipt(originID: origin, key: .init(sourceEventID: "delivery", orderLineID: line, branchID: "Main", segmentID: "one"))
            : .manual(originID: origin, sourceID: UUID())
        let lot = InventoryLot(id: lotID, foodID: line, name: "Wraps", source: source, revision: 1, location: .freezer,
            unit: .count, count: count ?? .exact(q(12)), observationID: observation, confirmedAt: now, updatedAt: now)
        let basket = try BasketPlan(id: shop.id, revisionID: UUID(),
            lines: [.init(id: line, name: "Wraps", quantity: q(12), expectedCost: .unknown(reason: "Review"))], createdAt: now)
        return Fixture(shop: shop, line: line, ledgerID: UUID(),
            basis: .init(originID: origin, inventoryRevision: 7, sourceHeads: [.init(journeyID: shop.id, revision: 4)]),
            scope: .init(journeyID: shop.id, journeyRevision: 4, basketRevisionID: basket.current.id, shopRevisionID: shop.revisionID, lineID: line),
            bindings: [.init(need: required, reservationID: requiredID), .init(need: protected, reservationID: protectedID)],
            lots: [lot], claims: claims,
            eligibility: [.init(lotID: lotID, source: source, observationID: observation, status: .eligible,
                receiptEvidenceDigest: receipt ? Data(repeating: 1, count: 32) : nil)], basket: basket)
    }
    private func evidence(_ f: Fixture, basis: Evidence.Basis? = nil, scope: Evidence.Scope? = nil,
                          lots: [InventoryLot]? = nil, claims: [InventoryReservation]? = nil,
                          eligibility: [Evidence.LotEligibility]? = nil) throws -> Evidence {
        let physical = lots ?? f.lots, promises = claims ?? f.claims
        let projection = try InventoryProjection.build(originID: f.basis.originID, lots: physical, reservations: promises, at: now)
        return try Evidence.review(scope: scope ?? f.scope, basis: basis ?? f.basis,
            requirement: LedgerPackRequirement.review(shop: f.shop, lineID: f.line), claimBindings: f.bindings,
            canonicalLots: physical, canonicalReservations: promises, projection: projection, eligibility: eligibility ?? f.eligibility)
    }
    private func choose(_ f: Fixture, evidence: Evidence, id: UUID = UUID(), offerID: String = "a") throws -> LedgerPackSelection {
        let required = try LedgerPackRequirement.review(shop: f.shop, lineID: f.line)
        let request = ComparisonRequest(itemName: required.name, needed: required.quantity,
            confirmedAtHome: try evidence.confirmedQuantity(for: required), protectedAmount: required.protectedQuantity,
            offerA: .init(id: "a", label: "Eight pack", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six pack", usableQuantity: q(6), price: .init(minorUnits: 250)))
        return try LedgerPackSelection(id: id, workspaceID: f.ledgerID, shop: f.shop, lineID: f.line,
            request: request, selectedOfferID: offerID, at: now, source: "Canonical pantry", canonicalStockEvidence: evidence)
    }
    private func applied(_ f: Fixture) throws -> BasketPlan {
        var basket = f.basket
        try basket.apply(.init(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: [.remove(f.line)]), at: now)
        return basket
    }
    private func appliedScope(_ f: Fixture, basket: BasketPlan, revision: Int64 = 5) -> Evidence.Scope {
        .init(journeyID: f.shop.id, journeyRevision: revision, basketRevisionID: basket.current.id,
            shopRevisionID: f.shop.revisionID, lineID: f.line)
    }

    func testGlobalProtectedClaimsGiveOnlyExistingScopedBackingWithoutReallocation() throws {
        let f = try fixture(otherProtected: true), proof = try evidence(f), choice = try choose(f, evidence: proof)
        XCTAssertEqual(choice.formatVersion, 3)
        XCTAssertEqual(choice.request.needed?.amount, q(12).amount); XCTAssertEqual(choice.request.needed?.unit, .count)
        XCTAssertEqual(choice.request.protectedAmount, q(4))
        XCTAssertEqual(choice.request.confirmedAtHome, q(4), "Neither all twelve physical units nor zero globally-free units is this shop's backing.")
        XCTAssertEqual(choice.selectedResult.packsToBuy, 1); XCTAssertEqual(choice.purchasedQuantity, q(8))
        XCTAssertEqual(try f.shop.quantity(forLineID: f.line)?.amount, q(12).amount)
        XCTAssertEqual(try f.shop.quantity(forLineID: f.line)?.unit, .count)
        XCTAssertEqual(proof.allocations.count, 1)
        let decoded = try JSONDecoder().decode(LedgerPackSelection.self, from: JSONEncoder().encode(choice))
        XCTAssertEqual(decoded, choice); XCTAssertNoThrow(try decoded.validate())
    }

    func testUnknownHeldAndIneligibleReceiptBackingNeverCreatesNoPurchase() throws {
        let unknown = try fixture(count: .someLeft), unknownEvidence = try evidence(unknown)
        let unknownChoice = try choose(unknown, evidence: unknownEvidence)
        XCTAssertNil(unknownChoice.request.confirmedAtHome); XCTAssertFalse(unknownChoice.isNoPurchase)
        XCTAssertEqual(unknownChoice.selectedResult.packsToBuy, 2)
        let f = try fixture(receipt: true), good = try evidence(f)
        XCTAssertTrue(try choose(f, evidence: good).isNoPurchase)
        let row = f.eligibility[0]
        let ineligible = Evidence.LotEligibility(lotID: row.lotID, source: row.source, observationID: row.observationID,
            status: .ineligible, receiptEvidenceDigest: row.receiptEvidenceDigest)
        let unsafe = try evidence(f, eligibility: [ineligible])
        XCTAssertNil(try unsafe.confirmedQuantity(for: LedgerPackRequirement.review(shop: f.shop, lineID: f.line)))
        XCTAssertFalse(try choose(f, evidence: unsafe).isNoPurchase)
        var claims = f.claims
        let first = claims[0]
        claims[0] = .init(id: first.id, originID: first.originID, revision: 2, foodID: first.foodID,
            lotID: first.lotID, name: first.name, amount: nil, priority: first.priority, state: .unresolved)
        XCTAssertNil(try evidence(f, claims: claims).confirmedQuantity(for: LedgerPackRequirement.review(shop: f.shop, lineID: f.line)))
    }

    func testExactReviewBasisAndAppliedBasketMaterialHaveSeparateFreshnessRules() throws {
        let f = try fixture(), proof = try evidence(f), choice = try choose(f, evidence: proof), basket = try applied(f)
        XCTAssertTrue(choice.isNoPurchase)
        XCTAssertFalse(try choice.isCurrent(in: f.shop, workspaceID: f.ledgerID))
        XCTAssertTrue(try choice.isCurrent(in: f.shop, workspaceID: f.ledgerID, currentCanonicalEvidence: proof))
        let advanced = Evidence.Basis(originID: f.basis.originID, inventoryRevision: 9,
            sourceHeads: [.init(journeyID: f.shop.id, revision: 6)])
        let live = try evidence(f, basis: advanced, scope: appliedScope(f, basket: basket, revision: 6))
        XCTAssertFalse(try choice.isCurrent(in: f.shop, workspaceID: f.ledgerID, currentCanonicalEvidence: live))
        XCTAssertTrue(try choice.isCurrentForAppliedBasket(in: f.shop, workspaceID: f.ledgerID,
            currentCanonicalEvidence: live, basket: basket, retainedSelections: [choice]))
        var workspace = LedgerWorkspace(shops: [f.shop], selectedShopID: f.shop.id)
        XCTAssertThrowsError(try workspace.recordPackSelection(choice, workspaceID: f.ledgerID, currentCanonicalEvidence: live))
        XCTAssertFalse(try choice.isCurrentForAppliedBasket(in: f.shop, workspaceID: f.ledgerID,
            currentCanonicalEvidence: live, basket: basket, retainedSelections: []))
        var next = basket
        try next.apply(.init(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(),
            changes: [.upsert(.init(id: f.line, name: "Wraps", quantity: q(12), expectedCost: .unknown(reason: "New review")))]), at: now)
        let nextLive = try evidence(f, basis: advanced, scope: appliedScope(f, basket: next, revision: 7))
        XCTAssertFalse(try choice.isCurrentForAppliedBasket(in: f.shop, workspaceID: f.ledgerID,
            currentCanonicalEvidence: nextLive, basket: next, retainedSelections: [choice]))
    }

    func testAnyPhysicalOrClaimHeadAndReceiptMappingChangeInvalidatesAppliedMaterial() throws {
        let f = try fixture(receipt: true), proof = try evidence(f), choice = try choose(f, evidence: proof), basket = try applied(f)
        let scope = appliedScope(f, basket: basket)
        var claims = f.claims
        claims.append(.init(id: UUID(), originID: f.basis.originID, revision: 1, foodID: UUID(), lotID: nil,
            name: "Other shop milk", amount: q(1)))
        let otherShop = try evidence(f, scope: scope, claims: claims)
        XCTAssertEqual(try otherShop.confirmedQuantity(for: LedgerPackRequirement.review(shop: f.shop, lineID: f.line)), q(12))
        XCTAssertFalse(try choice.isCurrentForAppliedBasket(in: f.shop, workspaceID: f.ledgerID,
            currentCanonicalEvidence: otherShop, basket: basket, retainedSelections: [choice]))
        let old = f.lots[0]
        let newer = InventoryLot(id: old.id, foodID: old.foodID, name: old.name, source: old.source, revision: 2,
            location: old.location, unit: old.unit, count: old.count, observationID: UUID(), confirmedAt: now, updatedAt: now)
        let eligibility = Evidence.LotEligibility(lotID: newer.id, source: newer.source, observationID: newer.observationID,
            status: .eligible, receiptEvidenceDigest: f.eligibility[0].receiptEvidenceDigest)
        let recounted = try evidence(f, scope: scope, lots: [newer], eligibility: [eligibility])
        XCTAssertFalse(try proof.hasSameMaterial(as: recounted), "Even the same recounted quantity is new physical evidence.")
        let changedReceipt = Evidence.LotEligibility(lotID: old.id, source: old.source, observationID: old.observationID,
            status: .eligible, receiptEvidenceDigest: Data(repeating: 2, count: 32))
        XCTAssertFalse(try proof.hasSameMaterial(as: evidence(f, scope: scope, eligibility: [changedReceipt])))
    }

    func testTamperedProofIncompleteGlobalGraphAndFreeStandingTotalAreRejected() throws {
        let f = try fixture(otherProtected: true), proof = try evidence(f)
        let requirement = try LedgerPackRequirement.review(shop: f.shop, lineID: f.line)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity, confirmedAtHome: q(12),
            protectedAmount: requirement.protectedQuantity,
            offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)))
        XCTAssertThrowsError(try LedgerPackSelection(workspaceID: f.ledgerID, shop: f.shop, lineID: f.line,
            request: request, selectedOfferID: "a", at: now, source: "Forged total", canonicalStockEvidence: proof))
        let projection = try InventoryProjection.build(originID: f.basis.originID, lots: f.lots, reservations: f.claims, at: now)
        XCTAssertThrowsError(try Evidence.review(scope: f.scope, basis: f.basis, requirement: requirement,
            claimBindings: f.bindings, canonicalLots: f.lots, canonicalReservations: Array(f.claims.prefix(2)),
            projection: projection, eligibility: f.eligibility))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as? [String: Any])
        let partition = try XCTUnwrap(object["partition"] as? [[String: Any]])
        object["partition"] = [partition[0], partition[0]]
        let corrupted = try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try corrupted.validate())
    }

    func testOriginalSelectionReplayPrecedesCurrentBasisButChangedBodyConflicts() throws {
        let f = try fixture(), proof = try evidence(f), selection = try choose(f, evidence: proof)
        var workspace = LedgerWorkspace(shops: [f.shop], selectedShopID: f.shop.id)
        XCTAssertTrue(try workspace.recordPackSelection(selection, workspaceID: f.ledgerID, currentCanonicalEvidence: proof))
        XCTAssertFalse(try workspace.recordPackSelection(selection, workspaceID: f.ledgerID), "Replay returns historical recognition without current-stock authority.")
        XCTAssertNil(try workspace.currentPackSelection(shopID: f.shop.id, lineID: f.line, workspaceID: f.ledgerID))
        XCTAssertEqual(try workspace.currentPackSelection(shopID: f.shop.id, lineID: f.line, workspaceID: f.ledgerID,
            currentCanonicalEvidence: proof), selection)
        let changed = try choose(f, evidence: proof, id: selection.id, offerID: "b")
        XCTAssertThrowsError(try workspace.recordPackSelection(changed, workspaceID: f.ledgerID, currentCanonicalEvidence: proof))
    }

    func testVersionOneAndTwoFilesDecodeWithoutCanonicalFields() throws {
        let f = try fixture(), requirement = try LedgerPackRequirement.review(shop: f.shop, lineID: f.line)
        let legacy = LedgerPackStockEvidence(sourceWorkspaceID: f.basis.originID, journeyID: f.shop.id,
            journeyRevision: 4, basketRevisionID: f.scope.basketRevisionID, shopRevisionID: f.shop.revisionID,
            lineID: f.line, listNeedIDs: f.bindings.map { $0.need.id },
            lots: [.init(id: UUID(), foodID: f.line, name: "Wraps", usable: q(12), confirmedAt: now, source: .pantry)],
            needs: f.bindings.map(\.need), reservations: [])
        for evidence in [nil, legacy] {
            let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
                confirmedAtHome: try evidence?.confirmedQuantity(for: requirement), protectedAmount: requirement.protectedQuantity,
                offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
                offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)))
            let choice = try LedgerPackSelection(workspaceID: f.ledgerID, shop: f.shop, lineID: f.line, request: request,
                selectedOfferID: "a", at: now, source: "Old file", stockEvidence: evidence)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(choice)) as? [String: Any])
            object.removeValue(forKey: "canonicalStockEvidence")
            let restored = try JSONDecoder().decode(LedgerPackSelection.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(restored, choice); XCTAssertNoThrow(try restored.validate()); XCTAssertNil(restored.canonicalStockEvidence)
        }
    }
}
