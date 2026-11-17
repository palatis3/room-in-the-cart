import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import RoomInTheCart

@MainActor final class RecordsPantryFilePickerTests: XCTestCase {
    private func picker() -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forOpeningContentTypes: [.pantryRecoveryPackage], asCopy: false)
    }

    func testAcceptedImportCompletionSurvivesNormalDismantle() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ritcpantry", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("fixture"), bytes = Data("bounded fixture".utf8)
        try bytes.write(to: file)
        let operation = UUID(), started = expectation(description: "Import callback started")
        let completed = expectation(description: "Accepted callback finished after dismissal")
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0, accepted = 0
        let dismissed = expectation(description: "Only the mounted operation is dismissed")
        let coordinator = RecordsPantryFilePicker.Coordinator(operationID: operation, mode: .importPackage,
            didDismiss: { id in XCTAssertEqual(id, operation); dismissed.fulfill() },
            willComplete: { id in XCTAssertEqual(id, operation); accepted += 1 }) { received, outcome in
            calls += 1
            XCTAssertEqual(received, operation)
            guard case .selectedForImport(let selected) = outcome else { return XCTFail("Expected selected import") }
            XCTAssertEqual(selected, url)
            await withCheckedContinuation { resume = $0; started.fulfill() }
            // An app-owned URL is valid even when startAccessing returns false.
            // The callback still owns its full async reading interval.
            XCTAssertEqual(try? Data(contentsOf: selected.appendingPathComponent("fixture")), bytes)
            completed.fulfill()
        }
        let controller = picker()
        coordinator.attach(controller)
        coordinator.documentPicker(controller, didPickDocumentsAt: [url])
        XCTAssertEqual(accepted, 1, "Acceptance must be synchronous, before an onDismiss can retire the operation")
        await fulfillment(of: [started], timeout: 2)
        coordinator.dismantle()
        coordinator.documentPickerWasCancelled(controller)
        resume?.resume()
        await fulfillment(of: [completed, dismissed], timeout: 2)
        XCTAssertEqual(calls, 1)
    }

    func testInvalidatedAndReplacedControllersCannotSubmitToAnotherOperation() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selected.ritcpantry")
        var oldCalls = 0, newCalls = 0
        let oldOperation = UUID(), newOperation = UUID(), finished = expectation(description: "Current operation selected")
        let old = RecordsPantryFilePicker.Coordinator(operationID: oldOperation, mode: .exportPackage(url)) { _, _ in oldCalls += 1 }
        let current = RecordsPantryFilePicker.Coordinator(operationID: newOperation, mode: .exportPackage(url)) { received, outcome in
            newCalls += 1
            XCTAssertEqual(received, newOperation)
            guard case .exported(let saved) = outcome else { return XCTFail("Expected exported destination") }
            XCTAssertEqual(saved, url)
            finished.fulfill()
        }
        let oldController = picker(), currentController = picker()
        old.attach(oldController); current.attach(currentController)
        old.invalidate()
        old.documentPicker(oldController, didPickDocumentsAt: [url])
        old.documentPickerWasCancelled(oldController)
        current.documentPicker(oldController, didPickDocumentsAt: [url])
        current.documentPicker(currentController, didPickDocumentsAt: [url])
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(oldCalls, 0); XCTAssertEqual(newCalls, 1)
    }

    func testDuplicateCancelAndSelectionDeliverOnlyTheirFirstOutcome() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selected.ritcpantry")
        for cancelFirst in [false, true] {
            let operation = UUID(), finished = expectation(description: cancelFirst ? "Cancelled once" : "Exported once")
            var calls = 0
            let coordinator = RecordsPantryFilePicker.Coordinator(operationID: operation, mode: .exportPackage(url)) { received, outcome in
                calls += 1
                XCTAssertEqual(received, operation)
                switch outcome {
                case .cancelled: XCTAssertTrue(cancelFirst)
                case .exported(let saved): XCTAssertFalse(cancelFirst); XCTAssertEqual(saved, url)
                default: XCTFail("Unexpected outcome")
                }
                finished.fulfill()
            }
            let controller = picker()
            coordinator.attach(controller)
            if cancelFirst { coordinator.documentPickerWasCancelled(controller) }
            coordinator.documentPicker(controller, didPickDocumentsAt: [url])
            coordinator.documentPickerWasCancelled(controller)
            coordinator.documentPicker(controller, didPickDocumentsAt: [url])
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(calls, 1)
        }
    }
}
