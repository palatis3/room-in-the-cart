import SwiftUI
import XCTest
@testable import RoomInTheCart

@MainActor final class RegionalAgeCheckTests: XCTestCase {
    func testOptionalSharingIsNeverRequested() async {
        let check = RegionalAgeCheck()
        await check.start(required: { false }, request: {
            XCTFail("Optional age ranges must stay private")
            return false
        })?.value
        XCTAssertEqual(check.state, .ready)
    }

    func testMandatorySharingAndDuplicateRequests() async {
        let check = RegionalAgeCheck()
        let running = check.start(required: { true }, request: { true })
        XCTAssertNil(check.start(required: { true }, request: { XCTFail(); return true }))
        await running?.value
        XCTAssertEqual(check.state, .ready)
        XCTAssertNil(check.start(required: { true }, request: { XCTFail(); return true }))
    }

    func testDecliningNeverAuthorizesAndRetryCanSucceed() async {
        let check = RegionalAgeCheck()
        await check.start(required: { true }, request: { false })?.value
        XCTAssertEqual(check.state, .declined)
        await check.start(required: { true }, request: { true })?.value
        XCTAssertEqual(check.state, .ready)
    }

    func testUnknownEligibilityAndNetworkFailureAllowRetry() async {
        let check = RegionalAgeCheck()
        await check.start(required: { throw URLError(.notConnectedToInternet) }, request: {
            XCTFail("Never ask while eligibility is unknown")
            return false
        })?.value
        XCTAssertEqual(check.state, .unavailable)
        await check.start(required: { true }, request: { throw URLError(.timedOut) })?.value
        XCTAssertEqual(check.state, .unavailable)
        await check.start(required: { false }, request: { XCTFail(); return false })?.value
        XCTAssertEqual(check.state, .ready)
    }

    func testStaleAppleAccountResponseCannotOpenNextSession() async throws {
        let check = RegionalAgeCheck()
        let entered = expectation(description: "Apple request started")
        var pending: CheckedContinuation<Bool, Never>?
        let first = check.start(required: { true }, request: {
            await withCheckedContinuation { pending = $0; entered.fulfill() }
        })
        await fulfillment(of: [entered], timeout: 5)
        check.reset()
        await check.start(required: { true }, request: { false })?.value
        try XCTUnwrap(pending).resume(returning: true)
        await first?.value
        XCTAssertEqual(check.state, .declined)
    }

    func testPendingLinkWaitsForAnActiveCheckedAccountAndClearsOnAccountChange() async throws {
        let check = RegionalAgeCheck()
        let link = try XCTUnwrap(URL(string: "ritc://capture"))
        check.deferredURL = link
        XCTAssertFalse(check.hasOpenedWorkspace)
        XCTAssertNil(check.approvedURL(active: true))
        await check.start(required: { true }, request: { false })?.value
        XCTAssertFalse(check.hasOpenedWorkspace)
        XCTAssertNil(check.approvedURL(active: true))
        await check.start(required: { false }, request: { XCTFail(); return false })?.value
        XCTAssertEqual(check.approvedURL(active: true), link)
        XCTAssertNil(check.approvedURL(active: false))
        check.reset()
        XCTAssertTrue(check.hasOpenedWorkspace)
        XCTAssertNil(check.deferredURL)
        check.deferredURL = link
        XCTAssertNil(check.approvedURL(active: true))
    }

    func testRecheckCoversPresentedReceiptDraftAndRestoresItsContents() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let originalKey = scene.keyWindow
        let source = UIWindow(windowScene: scene)
        let shopper = UIViewController()
        source.rootViewController = shopper
        source.makeKeyAndVisible()
        defer { source.isHidden = true; originalKey?.makeKey() }

        let draft = UIViewController()
        let line = UITextField()
        draft.view.addSubview(line)
        await withCheckedContinuation { resume in
            shopper.present(draft, animated: false) { resume.resume() }
        }
        line.text = "Avocados — 3 to put away"
        let check = RegionalAgeCheck()
        await check.start(required: { false }, request: { XCTFail(); return false })?.value
        check.reset()
        let shield = RegionalAgeWindowShield()
        shield.attach(to: source)
        defer { shield.uncover() }
        let controller = try XCTUnwrap(shield.cover(with: RegionalAgeStatus(check: check, retry: {}), active: true))
        XCTAssertTrue(check.hasOpenedWorkspace)
        XCTAssertIdentical(scene.keyWindow, controller.view.window)
        XCTAssertGreaterThan(try XCTUnwrap(controller.view.window).windowLevel.rawValue, source.windowLevel.rawValue)
        XCTAssertFalse(source.isUserInteractionEnabled)
        XCTAssertTrue(source.accessibilityElementsHidden)
        XCTAssertTrue(controller.view.accessibilityViewIsModal)
        XCTAssertIdentical(shopper.presentedViewController, draft)

        await check.start(required: { false }, request: { XCTFail(); return false })?.value
        shield.uncover()
        XCTAssertIdentical(scene.keyWindow, source)
        XCTAssertTrue(source.isUserInteractionEnabled)
        XCTAssertFalse(source.accessibilityElementsHidden)
        XCTAssertIdentical(shopper.presentedViewController, draft)
        XCTAssertEqual(line.text, "Avocados — 3 to put away")
    }

    func testFirstCheckDefersSwiftUIEditorAndAnotherCheckRetainsItsDraft() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let originalKey = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let check = RegionalAgeCheck()
        let controller = UIHostingController(rootView: CheckedShoppingWorkspace(check: check, phase: .active) { _ in
            ReceiptDraftEditor()
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; originalKey?.makeKey() }

        func receiptField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            for subview in view.subviews {
                if let field = receiptField(in: subview) { return field }
            }
            return nil
        }

        controller.view.layoutIfNeeded()
        XCTAssertNil(receiptField(in: controller.view))
        await check.start(required: { false }, request: { XCTFail(); return false })?.value
        let deadline = ContinuousClock.now + .seconds(2)
        while receiptField(in: controller.view) == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let field = try XCTUnwrap(receiptField(in: controller.view))
        field.text = "Avocados, three usable"
        field.sendActions(for: .editingChanged)
        check.reset()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertIdentical(receiptField(in: controller.view), field)
        await check.start(required: { false }, request: { XCTFail(); return false })?.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertIdentical(receiptField(in: controller.view), field)
        XCTAssertEqual(field.text, "Avocados, three usable")
    }

}


private struct ReceiptDraftEditor: View {
    @State private var line = ""
    var body: some View { TextField("Receipt line", text: $line) }
}
