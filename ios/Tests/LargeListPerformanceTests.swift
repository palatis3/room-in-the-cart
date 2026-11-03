import XCTest
import CoreDomain
@testable import RoomInTheCart

/// A measured simulator baseline, not a physical-device responsiveness claim.
/// Each run attaches its own timings; correctness stays independent of host load.
@MainActor final class LargeListPerformanceTests: XCTestCase {
    func testFiveHundredLineListChecksSearchesAndReopensWithoutLosingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large-list.sqlite")
        let model = LedgerModel(databaseURL: url)
        await model.open()
        let started = await model.startShop(title: "Fictional 500-line performance fixture")
        XCTAssertTrue(started)
        let shopID = try XCTUnwrap(model.shop?.id)
        let source = (0..<500).map { "Fixture arroz item \($0)" }.joined(separator: "\n")
        let importStart = ProcessInfo.processInfo.systemUptime
        let preview = try XCTUnwrap(model.shop).stageImport(text: source, source: .paste)
        let imported = await model.editShop(key: "performance-import", shopID: shopID) {
            try $0.commitImport(preview)
        }
        let importMilliseconds = (ProcessInfo.processInfo.systemUptime - importStart) * 1_000
        guard imported else { XCTFail(model.error ?? "Import failed"); return }
        let initial = try XCTUnwrap(model.shop)
        guard initial.lines.count == 500 else { XCTFail("Expected exactly 500 reviewed lines"); return }
        let originalIDs = initial.lines.map(\.id)
        var commitMilliseconds: [Double] = []
        var searchMilliseconds: [Double] = []
        let pulse = Pulse()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                pulse.mark()
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
        defer { heartbeat.cancel() }
        await Task.yield()
        for index in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            let changed = await model.editShop(key: "performance-check-\(index)", shopID: shopID) {
                try $0.setChecked(lineID: originalIDs[index], checked: true)
            }
            commitMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            XCTAssertTrue(changed, model.error ?? "Check failed")
            let searchStart = ProcessInfo.processInfo.systemUptime
            let matches = try XCTUnwrap(model.shop).search("item \(480 + index)")
            searchMilliseconds.append((ProcessInfo.processInfo.systemUptime - searchStart) * 1_000)
            XCTAssertEqual(matches.map(\.id), [originalIDs[480 + index]])
            await Task.yield()
        }
        heartbeat.cancel()
        let reopenStart = ProcessInfo.processInfo.systemUptime
        let reopened = LedgerModel(databaseURL: url)
        await reopened.open()
        let reopenMilliseconds = (ProcessInfo.processInfo.systemUptime - reopenStart) * 1_000
        let recovered = try XCTUnwrap(reopened.shop)
        XCTAssertEqual(recovered.lines.map(\.id), originalIDs)
        XCTAssertEqual(Set(recovered.recentlyChecked.map(\.id)), Set(originalIDs.prefix(20)))
        XCTAssertEqual(recovered.contributions.count, 500)
        let report: [String: Any] = [
            "fixture": "500 fictional unique pasted lines; 20 durable checks; 20 exact searches; reopen",
            "configuration": "Native test build; record device and OS from accompanying xcresult",
            "importMilliseconds": importMilliseconds,
            "commitMilliseconds": commitMilliseconds,
            "commitP95Milliseconds": percentile95(commitMilliseconds),
            "searchMilliseconds": searchMilliseconds,
            "searchP95Milliseconds": percentile95(searchMilliseconds),
            "reopenMilliseconds": reopenMilliseconds,
            "mainActorMaximumObservedGapDuringChecksAndSearchesMilliseconds": pulse.maximumGap * 1_000,
            "mainActorPulseCount": pulse.count,
            "limits": "Host-load-dependent baseline. No UI typing, frame rendering, lowest-device or physical-device acceptance."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "500-line-ledger-performance-baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
    private final class Pulse {
        private var previous: TimeInterval?
        var maximumGap: TimeInterval = 0
        var count = 0
        func mark() {
            let now = ProcessInfo.processInfo.systemUptime
            if let previous { maximumGap = max(maximumGap, now - previous) }
            previous = now
            count += 1
        }
    }
}
