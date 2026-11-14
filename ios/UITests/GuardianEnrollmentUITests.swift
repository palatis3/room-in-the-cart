#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import XCTest

@MainActor final class GuardianEnrollmentUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier:"dev.roominthecart.app.debug")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { capture("Guardian failure " + name) }
        app.terminate()
    }
    private func launch(_ scenario: String? = nil, spanish: Bool = false, rootSynthetic: Bool = false) {
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["--ui-testing","--guardian-enrollment-fixture","-AppleLanguages",spanish ? "(es)" : "(en)","-AppleLocale",spanish ? "es_US" : "en_US"]
        if spanish { app.launchArguments.append("--guardian-fixture-largest-text") }
        if let scenario { app.launchArguments.append(scenario) }
        if scenario == "--guardian-fixture-root" { app.launchArguments.append("--reset-guardian-root-fixture") }
        if rootSynthetic { app.launchArguments.append("--guardian-root-synthetic-vaults") }
        app.launch()
        if scenario == "--guardian-fixture-root" {
            XCTAssertTrue(app.buttons["Unlock private workspace"].waitForExistence(timeout:15))
            XCTAssertTrue(element("guardian.fixture.rootReady").waitForExistence(timeout:15))
        } else {
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout:15))
            if scenario == "--guardian-fixture-child" { reveal(element("guardian.childClaim")) }
        }
    }
    private func element(_ id: String) -> XCUIElement {
        let button = app.buttons.matching(identifier:id).firstMatch
        if button.exists { return button }
        return app.descendants(matching:.any).matching(identifier:id).firstMatch
    }
    private func viewport() -> CGRect {
        let container = app.collectionViews.firstMatch
        let bounds = container.exists ? container.frame.intersection(app.frame) : app.frame
        let nav = app.navigationBars.firstMatch, keyboard = app.keyboards.firstMatch
        var top = bounds.minY, bottom = bounds.maxY
        if nav.exists, nav.frame.intersects(bounds) { top = max(top,nav.frame.maxY) }
        if keyboard.exists { bottom = min(bottom,keyboard.frame.minY) }
        for toolbar in app.toolbars.allElementsBoundByIndex where toolbar.exists && toolbar.frame.minY > top {
            bottom = min(bottom,toolbar.frame.minY)
        }
        let evidence = app.staticTexts.matching(identifier:"guardian.fixture.rootReady").firstMatch
        if evidence.exists { bottom = min(bottom,evidence.frame.minY) }
        return CGRect(x:bounds.minX+8,y:top+4,width:max(1,bounds.width-16),height:max(1,bottom-top-8))
    }
    private func isInBar(_ value: XCUIElement) -> Bool {
        guard !value.identifier.isEmpty else { return false }
        return app.navigationBars.descendants(matching:.any).matching(identifier:value.identifier).firstMatch.exists ||
            app.toolbars.descendants(matching:.any).matching(identifier:value.identifier).firstMatch.exists
    }
    private func visible(_ value: XCUIElement, hitTarget: Bool) -> Bool {
        guard value.exists, !value.frame.isEmpty else { return false }
        if isInBar(value) { return value.isHittable && app.frame.contains(CGPoint(x:value.frame.midX,y:value.frame.midY)) }
        let area = viewport(), frame = value.frame
        if hitTarget {
            return value.isHittable && frame.minY >= area.minY && frame.maxY <= area.maxY && area.contains(CGPoint(x:frame.midX,y:frame.midY))
        }
        let intersection = area.intersection(frame)
        if frame.height > area.height {
            return !intersection.isNull && intersection.height >= area.height*0.80 && frame.minY <= area.minY+area.height*0.15
        }
        return !intersection.isNull && intersection.height >= min(44,frame.height)
    }
    private func scrollContent(upward: Bool) {
        let container = app.collectionViews.firstMatch
        guard container.exists else { XCTFail("No Form scroll container"); return }
        let area = viewport(), bounds = container.frame
        let start = container.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:area.midX-bounds.minX,dy:(upward ? area.maxY-area.height*0.20 : area.minY+area.height*0.20)-bounds.minY))
        let end = container.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:area.midX-bounds.minX,dy:(upward ? area.minY+area.height*0.20 : area.maxY-area.height*0.20)-bounds.minY))
        start.press(forDuration:0.05,thenDragTo:end)
    }
    private func alignTextBeginning(_ value: XCUIElement) {
        // An oversized accessibility label can intersect most of the viewport
        // while its first lines remain above the navigation bar. Capture the
        // actual beginning as well as the continuation of the warning.
        for _ in 0..<8 {
            let area=viewport(), delta=area.minY+12-value.frame.minY
            if abs(delta) <= 12 { break }
            let container=app.collectionViews.firstMatch, bounds=container.frame
            let distance=max(-area.height*0.40,min(area.height*0.40,delta))
            let start=container.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:area.midX-bounds.minX,dy:area.midY-bounds.minY))
            let end=start.withOffset(CGVector(dx:0,dy:distance))
            start.press(forDuration:0.05,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.3)
        }
        XCTAssertGreaterThanOrEqual(value.frame.minY,viewport().minY-4)
        XCTAssertLessThanOrEqual(value.frame.minY,viewport().minY+40)
    }
    private func reveal(_ value: XCUIElement, hitTarget: Bool = true, searchTowardStart: Bool = false) {
        for attempt in 0..<32 {
            if visible(value,hitTarget:hitTarget) { return }
            let area = viewport()
            let upward: Bool
            if value.exists, !value.frame.isEmpty { upward = value.frame.midY > area.midY }
            else { upward = searchTowardStart ? attempt >= 22 : attempt < 22 }
            scrollContent(upward:upward)
        }
        capture("Could not reveal " + value.identifier)
        XCTAssertTrue(visible(value,hitTarget:hitTarget),value.debugDescription)
    }
    private func tap(_ id: String, searchTowardStart: Bool = false) {
        let value = element(id)
        reveal(value, searchTowardStart: searchTowardStart)
        value.tap()
    }
    private func toggle(_ id: String, searchTowardStart: Bool = false) {
        let value=element(id); reveal(value, searchTowardStart: searchTowardStart)
        if value.value as? String != "1" { value.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap() }
    }
    private func type(_ id: String,_ value:String) { let field=element(id); reveal(field); field.tap(); field.typeText(value); if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() } }
    private func selectSetup() { tap("guardian.enrollment.10000000-0000-4000-8000-000000000001") }
    private func state(_ expected:String) {
        let result=element("guardian.state"); reveal(result,hitTarget:false)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@",expected),object:result)],timeout:10),.completed)
    }
    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot:app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let accessibility = XCTAttachment(string:app.debugDescription); accessibility.name = name + " accessibility"; accessibility.lifetime = .keepAlways; add(accessibility)
    }
    func testPrivateSettingsFirstSignInContinuesToHouseholdAndBackgroundReturnsToLock() {
        app.launchArguments = ["--ui-testing","--guardian-enrollment-fixture","--guardian-fixture-root",
            "--reset-guardian-root-fixture","--household-first-sign-in","-AppleLanguages","(en)","-AppleLocale","en_US"]
        app.launch()
        let settings = app.buttons["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout:15))
        settings.tap()
        tap("Household requests")
        type("Email", "shopper@example.invalid")
        tap("Email me a code")
        type("Email sign-in code", "123456")
        tap("Verify code")

        // Nothing else is tapped between verification and choosing the household.
        let family = app.buttons["Fixture family"]
        XCTAssertTrue(family.waitForExistence(timeout:10))
        XCTAssertFalse(family.isEnabled)
        XCTAssertEqual(app.switches["Keep my existing work private on this phone"].value as? String,"0")
        XCTAssertEqual(app.tabBars.count,0)
        XCTAssertFalse(app.buttons["settings"].exists)
        capture("First sign-in continued to household with consent off")
        toggle("Keep my existing work private on this phone")
        XCTAssertTrue(family.isEnabled)
        tap("Fixture family")
        XCTAssertTrue(app.buttons["Refresh household"].waitForExistence(timeout:10))
        XCTAssertEqual(app.tabBars.count,0)
        XCTAssertFalse(app.staticTexts["Fictional adult private item"].exists)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:8))
        app.activate()
        let unlock = app.buttons["Unlock private workspace"]
        XCTAssertTrue(unlock.waitForExistence(timeout:10))
        XCTAssertFalse(family.exists)
        XCTAssertEqual(app.tabBars.count,0)
        app.buttons["Household requests"].tap()
        XCTAssertTrue(app.buttons["Unlock household access"].waitForExistence(timeout:5))
        XCTAssertFalse(family.exists)

        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-guardian-root-fixture" }
        app.launch()
        XCTAssertTrue(unlock.waitForExistence(timeout:10))
        XCTAssertFalse(family.exists)
        XCTAssertEqual(app.tabBars.count,0)
    }
    func testRealRootLeaveCancelAndConfirmedExitRestoreLockedAdultAccess() { rootLifecycle(synthetic:false) }
    func testRealRootColdChildMarkerAndSyntheticVaultCleanupPreserveAdultData() { rootLifecycle(synthetic:true) }
    private func rootLifecycle(synthetic: Bool) {
        let evidence = synthetic ? "Synthetic child vaults" : "Empty child vaults"
        launch("--guardian-fixture-root",rootSynthetic:synthetic)
        XCTAssertEqual(app.tabBars.count,0)
        app.buttons["Household requests"].tap()
        tap("household.childInvitation")
        var leave=element("guardian.leaveChildSpace")
        XCTAssertTrue(leave.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["Unlock private workspace"].exists)
        XCTAssertFalse(element("settings.help").exists)
        XCTAssertEqual(app.tabBars.count,0)
        XCTAssertFalse(app.staticTexts["Fictional adult private item"].exists)

        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:leave)],timeout:10),.completed)
        leave.tap()
        XCTAssertTrue(element("guardian.leaveChildCancel").waitForExistence(timeout:5))
        element("guardian.leaveChildCancel").tap()
        XCTAssertTrue(leave.exists)
        XCTAssertFalse(app.buttons["Unlock private workspace"].exists)
        XCTAssertEqual(app.tabBars.count,0)
        capture(evidence + " child root after cancel")

        // Kill while child mode is active. The real protected marker must choose
        // child root before any adult account/store is restored on the next launch.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-guardian-root-fixture" }
        app.launch()
        leave=element("guardian.leaveChildSpace")
        XCTAssertTrue(leave.waitForExistence(timeout:15))
        XCTAssertTrue(element("guardian.fixture.rootReady").waitForExistence(timeout:15))
        XCTAssertFalse(app.buttons["Unlock private workspace"].exists)
        XCTAssertFalse(element("settings.help").exists)
        XCTAssertEqual(app.tabBars.count,0)
        XCTAssertFalse(app.staticTexts["Fictional adult private item"].exists)
        capture(evidence + " cold child root")

        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:leave)],timeout:10),.completed)
        leave.tap()
        let confirm=app.buttons["Remove child session and return to locked adult access"]
        XCTAssertTrue(confirm.waitForExistence(timeout:5)); confirm.tap()
        // No explicit fixture refresh: production RootView must observe presented=false.
        XCTAssertTrue(app.buttons["Unlock private workspace"].waitForExistence(timeout:10))
        XCTAssertFalse(element("guardian.leaveChildSpace").exists)
        XCTAssertEqual(app.tabBars.count,0)
        XCTAssertFalse(app.buttons["Shop"].exists); XCTAssertFalse(app.buttons["Records"].exists)
        XCTAssertFalse(app.staticTexts["Fictional adult private item"].exists)
        let exitNotice=app.staticTexts.matching(identifier:"guardian.childExitNotice").firstMatch
        XCTAssertTrue(exitNotice.waitForExistence(timeout:5))
        XCTAssertTrue(visible(exitNotice,hitTarget:true))
        XCTAssertEqual(exitNotice.label,"Child access was removed from this device. Remote device revocation could not be confirmed; ask your guardian to review active permission.")
        XCTAssertFalse(app.staticTexts["Fictional adult private item"].exists)
        capture(evidence + " locked adult exit with honest remote cleanup notice")
        element("guardian.fixture.checkPreservation").tap()
        let preserved=element("guardian.fixture.preservation")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","adult records and inbox preserved; child vaults empty; adult locked"),object:preserved)],timeout:10),.completed)
        capture(evidence + " preserved private records and inbox")

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Unlock private workspace"].waitForExistence(timeout:15))
        XCTAssertFalse(element("guardian.leaveChildSpace").exists)
        XCTAssertEqual(app.tabBars.count,0)
    }
    func testUnavailableNeverOffersCreationOrAdultVerification() {
        launch("--guardian-fixture-unavailable")
        XCTAssertTrue(element("guardian.unavailable").exists)
        XCTAssertFalse(element("guardian.create").exists); XCTAssertFalse(element("guardian.verify").exists)
        capture("Guardian unavailable English")
    }
    func testSpanishLargestTextUnavailableGateRemainsReadableAndClosed() {
        launch("--guardian-fixture-unavailable",spanish:true)
        let unavailable=app.staticTexts.matching(identifier:"guardian.unavailable").firstMatch
        reveal(unavailable,hitTarget:false)
        alignTextBeginning(unavailable)
        XCTAssertTrue(unavailable.label.contains("no está disponible"))
        XCTAssertFalse(element("guardian.create").exists); XCTAssertFalse(element("guardian.verify").exists)
        capture("Guardian unavailable Spanish largest text beginning")
        scrollContent(upward:true)
        capture("Guardian unavailable Spanish largest text continuation")
    }
    func testUncertainAttemptCanRefreshButCannotSendAnotherVerification() {
        launch("--guardian-fixture-uncertain")
        selectSetup()
        state("Verification result is not confirmed")
        XCTAssertFalse(element("guardian.verify").exists)
        tap("guardian.refresh")
        XCTAssertFalse(element("guardian.verify").exists)
        reveal(element("guardian.fixture.verificationRequests"),hitTarget:false)
        XCTAssertEqual(element("guardian.fixture.verificationRequests").label,"0")
    }
    func testNoticeDeclarationVerificationPermissionPairingAndDialogCancellation() {
        launch()
        reveal(element("guardian.create")); XCTAssertFalse(element("guardian.create").isEnabled)
        toggle("guardian.reviewedNotice", searchTowardStart: true); type("guardian.childLocation","US"); toggle("guardian.declaration")
        tap("guardian.create"); state("Adulthood verification needed")
        XCTAssertFalse(element("guardian.grant").exists)
        tap("guardian.verify"); state("Waiting for verified adulthood result")
        XCTAssertFalse(element("guardian.grant").exists)
        tap("guardian.fixture.providerVerified", searchTowardStart: true); state("Adulthood verified; permission still needed")
        reveal(element("guardian.grant")); XCTAssertFalse(element("guardian.grant").isEnabled)
        toggle("guardian.reviewedNotice", searchTowardStart: true); type("guardian.childAlias","Sam")
        type("guardian.childSignInEmail","fictional-child@example.invalid"); toggle("guardian.grantReviewed")
        tap("guardian.grant"); state("Permission recorded; child invitation needed")
        capture("Guardian separate permission recorded")
        tap("guardian.invite"); XCTAssertTrue(element("guardian.invitationToken").waitForExistence(timeout:10))
        tap("household.shareBrowserInvitation")
        guard let closeShare = readySystemShareClose(in: app) else {
            XCTFail("Expected the system share sheet for the browser invitation"); return
        }
        closeShare.tap()
        XCTAssertTrue(element("guardian.invitationToken").waitForExistence(timeout: 10))
        let clearRetry=app.buttons["Check status, then clear local retry"]; reveal(clearRetry); clearRetry.tap()
        XCTAssertTrue(element("guardian.clearRetryCancel").waitForExistence(timeout:5)); element("guardian.clearRetryCancel").tap()
        XCTAssertTrue(element("guardian.invitationToken").exists)
        let continueSharing=app.buttons["I finished sharing; continue to pairing"]; reveal(continueSharing); continueSharing.tap()
        tap("guardian.fixture.childClaimed", searchTowardStart: true); state("Child device is waiting for your confirmation")
        reveal(element("guardian.confirmChild")); XCTAssertFalse(element("guardian.confirmChild").isEnabled)
        type("guardian.pairingCode","ABCD2345"); tap("guardian.confirmChild")
        state("Child device confirmed; finish on that device")
        XCTAssertFalse(app.staticTexts["Own-request access is active"].exists)
        capture("Guardian pairing confirmed without local activation")
    }
    func testChildForgetCancelAndForegroundKeepTheSamePairingWithoutActivation() {
        launch("--guardian-fixture-child")
        type("guardian.childToken","fixture-invitation"); tap("guardian.childClaim")
        XCTAssertTrue(element("guardian.childPairingCode").waitForExistence(timeout:10))
        let code=element("guardian.childPairingCode").label
        tap("guardian.childForget")
        XCTAssertTrue(element("guardian.childForgetCancel").waitForExistence(timeout:5)); element("guardian.childForgetCancel").tap()
        XCTAssertEqual(element("guardian.childPairingCode").label,code)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(element("guardian.childRetry").waitForExistence(timeout:10)); tap("guardian.childRetry")
        XCTAssertEqual(element("guardian.childPairingCode").label,code)
        XCTAssertFalse(element("guardian.childFinish").exists)
    }
    func testCancelSetupDialogHasExplicitCancelAndForegroundRestoresStatus() {
        launch("--guardian-fixture-awaiting")
        selectSetup()
        let cancel=app.buttons["Cancel this setup"]; reveal(cancel); cancel.tap()
        XCTAssertTrue(element("guardian.cancelSetupCancel").waitForExistence(timeout:5)); element("guardian.cancelSetupCancel").tap()
        state("Adulthood verification needed")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout:10))
        tap("guardian.refresh")
        selectSetup()
        state("Adulthood verification needed")
        reveal(element("guardian.verify"))
        XCTAssertTrue(element("guardian.verify").exists)
    }
}
#endif
