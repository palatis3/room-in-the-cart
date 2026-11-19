import XCTest
import UIKit
@testable import RoomInTheCart

@MainActor final class PantryVoiceInputTests: XCTestCase {
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Pantry speech did not settle", file: file, line: line)
    }

    func testSystemPermissionRetainsOnlyItsInactiveViewAndFencesPantryActions() throws {
        let window = PantryVoicePromptWindow()
        let adult = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryVoicePromptScope(adult: adult, origin: UUID(), ledger: UUID(), generation: UUID())
        XCTAssertFalse(window.retains(scope, phase: .inactive))
        XCTAssertNil(window.begin(scope, phase: .inactive))
        let token = try XCTUnwrap(window.begin(scope, phase: .active))
        XCTAssertNil(window.begin(scope, phase: .active))
        XCTAssertTrue(window.holdsPresentation(scope))
        XCTAssertFalse(window.holdsPresentation(.init(adult: adult, origin: scope.origin, ledger: UUID(), generation: scope.generation)))
        XCTAssertFalse(window.allowsPantryAction(appActive: false))
        window.sceneChanged(.inactive)
        XCTAssertTrue(window.retains(scope, phase: .inactive))
        XCTAssertFalse(window.retains(scope, phase: .background))
        XCTAssertFalse(window.retains(nil, phase: .inactive))
        XCTAssertFalse(window.retains(.init(adult: adult, origin: scope.origin, ledger: scope.ledger, generation: UUID()), phase: .inactive))
        XCTAssertFalse(window.retains(.init(adult: adult, origin: UUID(), ledger: scope.ledger, generation: scope.generation), phase: .inactive))
        let other = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        XCTAssertFalse(window.retains(.init(adult: other, origin: scope.origin, ledger: scope.ledger, generation: scope.generation), phase: .inactive))
        XCTAssertFalse(window.allowsPantryAction(appActive: true))
        window.recognitionReady(token, appActive: false)
        XCTAssertTrue(window.retains(scope, phase: .inactive))
        window.sceneChanged(.active)
        XCTAssertNil(window.token)
        XCTAssertTrue(window.allowsPantryAction(appActive: true))
    }

    func testNotificationDenialWaitsForSameAdultToReturnFromSystemAlert() async throws {
        let adult = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryVoicePromptScope(adult: adult, origin: UUID(), ledger: UUID(), generation: UUID())
        let window = PantryVoicePromptWindow()
        var active = true
        let answer = Task {
            try await window.requestNotification(in: scope, phase: .active, currentScope: { scope }, appActive: { active }) {
                active = false
                window.sceneChanged(.inactive)
                return false
            }
        }
        await settle { window.retains(scope, phase: .inactive) }
        XCTAssertFalse(window.allowsPantryAction(appActive: false))
        active = true
        window.sceneChanged(.active)
        let allowed = try await answer.value
        XCTAssertFalse(allowed)
        XCTAssertNil(window.token)
    }

    func testNotificationResponseBeforeSceneInterruptionRetainsOnlyTheReviewedScope() async throws {
        let adult = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryVoicePromptScope(adult: adult, origin: UUID(), ledger: UUID(), generation: UUID())
        let window = PantryVoicePromptWindow()
        let allowed = try await window.requestNotification(in: scope, phase: .active,
            currentScope: { scope }, appActive: { true }) { false }
        XCTAssertFalse(allowed)
        window.sceneChanged(.inactive)
        XCTAssertTrue(window.retains(scope, phase: .inactive))
        XCTAssertFalse(window.allowsPantryAction(appActive: false))
        window.sceneChanged(.active)
        XCTAssertNil(window.token)
    }

    func testNotificationPermissionCannotCarryAcrossBackgroundOrAnotherAdult() async throws {
        let adult = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryVoicePromptScope(adult: adult, origin: UUID(), ledger: UUID(), generation: UUID())
        let other = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        for background in [true, false] {
            let window = PantryVoicePromptWindow()
            var current = scope
            do {
                _ = try await window.requestNotification(in: scope, phase: .active, currentScope: { current }, appActive: { true }) {
                    window.sceneChanged(.inactive)
                    if background {
                        window.sceneChanged(.background)
                        XCTAssertFalse(window.holdsPresentation(scope))
                    } else {
                        current = .init(adult: other, origin: scope.origin, ledger: scope.ledger, generation: scope.generation)
                        XCTAssertFalse(window.holdsPresentation(current))
                    }
                    window.sceneChanged(.active)
                    return true
                }
                XCTFail("An old notification request survived a privacy boundary")
            } catch PantryDigestFailure.changed {}
            XCTAssertNil(window.token)
        }
    }

    func testPermissionResultBeforeSceneInterruptionRetainsOnlyUntilReturn() throws {
        let adult = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryVoicePromptScope(adult: adult, origin: UUID(), ledger: UUID(), generation: UUID())
        let window = PantryVoicePromptWindow()
        let token = try XCTUnwrap(window.begin(scope, phase: .active))
        // The first permission's foreground cycle cannot stand in for the second one.
        window.sceneChanged(.inactive)
        window.sceneChanged(.active)
        window.nextPermission(token)
        window.recognitionReady(token, appActive: true)
        XCTAssertEqual(window.token, token)
        window.sceneChanged(.inactive)
        XCTAssertTrue(window.retains(scope, phase: .inactive))
        XCTAssertFalse(window.allowsPantryAction(appActive: false))
        window.sceneChanged(.active)
        XCTAssertNil(window.token)
    }

    func testBackgroundAndCancellationRetirePromptWithoutDisturbingLaterPermissionRun() throws {
        let adult = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryVoicePromptScope(adult: adult, origin: UUID(), ledger: UUID(), generation: UUID())
        let window = PantryVoicePromptWindow()
        let old = try XCTUnwrap(window.begin(scope, phase: .active))
        window.sceneChanged(.background)
        XCTAssertFalse(window.retains(scope, phase: .inactive))
        let new = try XCTUnwrap(window.begin(scope, phase: .active))
        window.cancel(old)
        window.recognitionReady(old, appActive: true)
        XCTAssertEqual(window.token, new)
        window.cancel(new)
        XCTAssertNil(window.token)
    }

    func testTemporaryPrivacyCoverHidesAnAppWindowWithoutTakingKeyboardFocus() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.keyWindow)
        let originalAccessibility = window.accessibilityElementsHidden
        defer { window.accessibilityElementsHidden = originalAccessibility }

        for initiallyHidden in [false, true] {
            window.accessibilityElementsHidden = initiallyHidden
            XCTAssertEqual(window.accessibilityElementsHidden, initiallyHidden)
            let anchor = PantryVoicePrivacyCover.Anchor()
            window.addSubview(anchor)
            defer { anchor.removeFromSuperview() }
            let cover = try XCTUnwrap(anchor.cover)
            XCTAssertFalse(cover.isHidden)
            XCTAssertFalse(cover.isKeyWindow)
            XCTAssertGreaterThan(cover.windowLevel.rawValue, UIWindow.Level.alert.rawValue)
            XCTAssertTrue(window.accessibilityElementsHidden)
            XCTAssertTrue(scene.keyWindow === window)
            anchor.removeFromSuperview()
            XCTAssertTrue(cover.isHidden)
            XCTAssertEqual(window.accessibilityElementsHidden, initiallyHidden)
        }
    }

    func testDictationUsesReviewedSpanishWordingOnceAndPreservesIndependentTyping() async throws {
        let session = PantryVoiceSession(), speech = PantryTestSpeech()
        var draft = "A mano"
        XCTAssertNil(session.capture)
        XCTAssertNil(speech.locale)
        session.start(localeIdentifier: "es_MX", authorized: { true }, makeSpeech: { speech })
        let capture = try XCTUnwrap(session.capture)
        await settle { capture.listening }
        XCTAssertEqual(speech.locale, "es-US")
        speech.update("abrí arroz ayer", final: false)
        await settle { capture.candidate != nil }
        session.use(capture, authorizedNow: { true }) { _ in XCTFail("Partial listening result was used") }
        draft = "Corregido a mano"
        speech.update("abrí el arroz ayer", final: true)
        await settle { !capture.busy }
        XCTAssertEqual(draft, "Corregido a mano")
        session.use(capture, authorizedNow: { true }) { draft += "\n" + $0 }
        session.use(capture, authorizedNow: { true }) { _ in XCTFail("A retired result was reused") }
        XCTAssertEqual(draft, "Corregido a mano\nabrí el arroz ayer")
        XCTAssertNil(capture.candidate)
        XCTAssertNil(session.capture)
    }

    func testPermissionDenialUnsupportedLocaleAndLockedScopeAllowTypingWithoutAudio() async throws {
        let session = PantryVoiceSession()
        session.start(localeIdentifier: "fr_CA", authorized: { false }, makeSpeech: { XCTFail(); return PantryTestSpeech() })
        XCTAssertNil(session.capture)
        session.start(localeIdentifier: "fr_CA", authorized: { true }, makeSpeech: { XCTFail(); return PantryTestSpeech() })
        XCTAssertTrue(session.unsupportedLanguage)
        let speech = PantryTestSpeech()
        speech.failure = .permissionDenied
        session.start(localeIdentifier: "en_GB", authorized: { true }, makeSpeech: { speech })
        let capture = try XCTUnwrap(session.capture)
        await settle { capture.failure == .permissionDenied }
        XCTAssertEqual(speech.locale, "en-US")
        XCTAssertNil(capture.candidate)
        XCTAssertFalse(capture.listening)
        XCTAssertFalse(session.unsupportedLanguage)
        session.use(capture, authorizedNow: { true }) { _ in XCTFail("Denied permission produced wording") }
    }

    func testStoppingAllowsReviewButRevokedScopeCannotUseThePartialTranscript() async throws {
        let session = PantryVoiceSession(), speech = PantryTestSpeech()
        var authorized = true
        session.start(localeIdentifier: "en", authorized: { authorized }, makeSpeech: { speech })
        let capture = try XCTUnwrap(session.capture)
        await settle { capture.listening }
        speech.update("opened beans", final: false)
        await settle { capture.candidate != nil }
        capture.stopSpeech()
        XCTAssertEqual(capture.candidate?.text, "opened beans")
        XCTAssertFalse(capture.listening)
        authorized = false
        session.use(capture, authorizedNow: { true }) { _ in XCTFail("Changed pantry scope accepted a transcript") }
        XCTAssertNil(session.capture)
        XCTAssertNil(capture.candidate)
        speech.update("late words", final: true)
        await Task.yield()
        XCTAssertNil(capture.candidate)
    }

    func testRouteExitDuringPermissionAndLateStartCannotStopTheNextRun() async throws {
        let session = PantryVoiceSession(), first = PantryTestSpeech(), second = PantryTestSpeech()
        first.delayPermission = true
        session.start(localeIdentifier: "en", authorized: { true }, makeSpeech: { first })
        let old = try XCTUnwrap(session.capture)
        await settle { first.permission != nil }
        session.cancel()
        session.start(localeIdentifier: "en", authorized: { true }, makeSpeech: { second })
        let current = try XCTUnwrap(session.capture)
        await settle { current.listening }
        first.permission?.resume()
        await settle { first.stops >= 2 }
        first.update("late and private", final: true)
        XCTAssertTrue(current.listening)
        XCTAssertNil(old.candidate)
        XCTAssertNil(current.candidate)
        second.update("new wording", final: false)
        await settle { current.candidate?.text == "new wording" }
        session.cancel()
        XCTAssertFalse(current.listening)
        XCTAssertNil(current.candidate)
        XCTAssertNil(session.capture)
    }
}

@MainActor private final class PantryTestSpeech: CaptureSpeechService {
    var locale: String?
    var failure: CaptureFailure?
    var delayPermission = false
    var permission: CheckedContinuation<Void, Never>?
    var stops = 0
    private var continuation: AsyncThrowingStream<SpeechCaptureUpdate, Error>.Continuation?

    func begin(localeIdentifier: String) async throws -> AsyncThrowingStream<SpeechCaptureUpdate, Error> {
        locale = localeIdentifier
        if delayPermission { await withCheckedContinuation { permission = $0 } }
        if let failure { throw failure }
        return AsyncThrowingStream { continuation = $0 }
    }

    func update(_ text: String, final: Bool) {
        continuation?.yield(.init(text: text, isFinal: final, uncertain: true))
    }

    func stop() {
        stops += 1
        continuation?.finish()
    }
}
