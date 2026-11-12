import XCTest
@testable import RoomInTheCart

final class CorrectionSettingsOutcomeTests: XCTestCase {
    private func spelling(_ original: String, _ replacement: String) -> CaptureCorrection {
        CaptureCorrection(id: UUID(), original: original, replacement: replacement, createdAt: .distantPast)
    }

    @MainActor func testRegionalCaptureFilesRemainManageableWithoutReenablingOrMixingLanguages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureCorrectionStore(directory: directory)
        let profile = "local:" + UUID().uuidString
        func scope(_ locale: String, profileID: String? = nil) -> CaptureCorrectionScope {
            CaptureCorrectionScope(profileID: profileID ?? profile, localeIdentifier: locale)
        }
        let spanish = scope(CaptureCorrectionScope.appLanguage("es-MX"))
        let english = scope(CaptureCorrectionScope.appLanguage("en-GB"))
        XCTAssertEqual(spanish, scope("es-US"))
        XCTAssertEqual(english, scope("en-US"))
        let mexico = scope("es_MX"), britain = scope("en_GB"), custom = scope("en_US@calendar=buddhist")
        let other = scope("es_MX", profileID: "local:" + UUID().uuidString)
        let connected = try XCTUnwrap(CaptureCorrectionScope.connected(subject: "adult-test",
            householdID: UUID().uuidString, memberID: UUID().uuidString, localeIdentifier: "es_MX"))
        for previous in [mexico, britain, custom, other, connected] {
            try await store.setEnabled(true, scope: previous)
            try await store.remember(original: "tortiyas", replacement: "tortillas", scope: previous)
        }
        let settings = CaptureCorrectionsModel(store: store)
        await settings.bind(spanish, includePreviousRegions: true)
        XCTAssertEqual(settings.snapshot, .init(), "An earlier region's opt-in cannot enable Spanish")
        XCTAssertEqual(settings.previousRegions.count, 3)
        let previousMexico = try XCTUnwrap(settings.previousRegions.first { $0.localeIdentifier == "es-MX" })
        let previousBritain = try XCTUnwrap(settings.previousRegions.first { $0.localeIdentifier == "en-GB" })
        let previousCustom = try XCTUnwrap(settings.previousRegions.first { $0 != previousMexico && $0 != previousBritain })
        let capture = CaptureCorrectionsModel(store: store)
        await capture.bind(spanish)
        await capture.setEnabled(true)
        await capture.remember(original: "limmon", replacement: "limón")
        await settings.bind(spanish)
        let saved = try XCTUnwrap(settings.suggestion(for: "limmon"))
        await settings.forget(saved.id)
        await settings.setEnabled(false)
        await capture.bind(spanish)
        XCTAssertEqual(capture.snapshot, .init())
        await capture.bind(english)
        XCTAssertEqual(capture.snapshot, .init())
        await settings.bind(previousMexico)
        let retained = try XCTUnwrap(settings.suggestion(for: "tortiyas"))
        await settings.forget(retained.id)
        await settings.bind(previousCustom)
        await settings.setEnabled(false)
        let reopened = CaptureCorrectionStore(directory: directory)
        let forgotten = try await reopened.load(mexico), deleted = try await reopened.load(custom)
        XCTAssertEqual(forgotten, .init(enabled: true))
        XCTAssertEqual(deleted, .init())
        let remaining = try await reopened.previousRegionalScopes(for: english)
        XCTAssertEqual(Set(remaining), [previousMexico, previousBritain])
        let preserved = try await reopened.load(britain)
        XCTAssertEqual(preserved.entries.count, 1)
        try await reopened.eraseProfile(spanish)
        let retired = try await reopened.previousRegionalScopes(for: english)
        XCTAssertTrue(retired.isEmpty)
        for isolated in [other, connected] {
            let unchanged = try await reopened.load(isolated)
            XCTAssertEqual(unchanged.entries.count, 1)
        }
        do {
            try await reopened.setEnabled(true, scope: previousCustom)
            XCTFail("A deleted regional file must never be recreated through Settings")
        } catch CaptureCorrectionFailure.invalidScope {}
    }

    func testForgetAccessibilityLabelIdentifiesBothProductSpellingsAndTheTarget() {
        let first = spelling("tortiyas", "tortillas"), second = spelling("frijolles", "frijoles")
        let firstLabel = CorrectionSettingsOutcome.forgetLabel(first)
        let secondLabel = CorrectionSettingsOutcome.forgetLabel(second)
        XCTAssertTrue(firstLabel.contains(first.original)); XCTAssertTrue(firstLabel.contains(first.replacement))
        XCTAssertTrue(secondLabel.contains(second.original)); XCTAssertTrue(secondLabel.contains(second.replacement))
        XCTAssertNotEqual(firstLabel, secondLabel, "The VoiceOver button rotor must identify the target without relying on sibling text")
    }

    func testForgetSuccessRequiresConfirmedPostOperationAbsenceAndKeepsTheDeletedTargetInResult() {
        let removed = spelling("tortiyas", "tortillas"), retained = spelling("frijolles", "frijoles")
        let action = CorrectionSettingsAction.forget(removed)
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(action, snapshot: .init(enabled: true, entries: [retained]), failed: false), .forgotten(removed))
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(action, snapshot: .init(enabled: true), failed: false), .forgotten(removed), "Forgetting the last row still leaves an explicit result for accessibility focus")
        let text = CorrectionSettingsOutcome.forgotten(removed).text
        XCTAssertTrue(text.contains(removed.original)); XCTAssertTrue(text.contains(removed.replacement))
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(action, snapshot: .init(enabled: true, entries: [removed, retained]), failed: false), .unconfirmed)
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(action, snapshot: .init(enabled: true, entries: [retained]), failed: true), .unconfirmed)
    }

    func testOptOutSuccessRequiresDisabledEmptyReloadAndDoesNotMislabelFailure() {
        let entry = spelling("tortiyas", "tortillas")
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(.disable, snapshot: .init(), failed: false), .disabled)
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(.disable, snapshot: .init(enabled: true), failed: false), .unconfirmed)
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(.disable, snapshot: .init(enabled: false, entries: [entry]), failed: false), .unconfirmed)
        XCTAssertEqual(CorrectionSettingsOutcome.resolve(.disable, snapshot: .init(), failed: true), .unconfirmed)
        XCTAssertFalse(CorrectionSettingsOutcome.disabled.text.isEmpty)
        XCTAssertFalse(CorrectionSettingsOutcome.unconfirmed.text.isEmpty)
    }
}
