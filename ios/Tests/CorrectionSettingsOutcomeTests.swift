import XCTest
@testable import RoomInTheCart

final class CorrectionSettingsOutcomeTests: XCTestCase {
    private func spelling(_ original: String, _ replacement: String) -> CaptureCorrection {
        CaptureCorrection(id: UUID(), original: original, replacement: replacement, createdAt: .distantPast)
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
