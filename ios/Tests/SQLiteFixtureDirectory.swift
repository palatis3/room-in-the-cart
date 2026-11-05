import XCTest

/// A test's `defer` runs while its local models can still own SQLite handles.
/// Delete only after the test returns and any asynchronous work releases them.
@MainActor final class SQLiteFixtureDirectory {
    private final class Owner {
        weak var value: AnyObject?
        let name: String
        init(_ value: AnyObject) { self.value = value; name = String(describing: type(of: value)) }
    }
    private var owners: [Owner] = []

    init(_ directory: URL, test: XCTestCase, file: StaticString = #filePath, line: UInt = #line) {
        test.addTeardownBlock { @MainActor [self] in
            let deadline = ContinuousClock.now + .seconds(5)
            while owners.contains(where: { $0.value != nil }) {
                guard ContinuousClock.now < deadline else {
                    let retained = owners.filter { $0.value != nil }.map(\.name).joined(separator: ", ")
                    XCTFail("SQLite fixture owners did not release before teardown: \(retained)", file: file, line: line)
                    return // Keep the files intact while their connections are open.
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    func track(_ values: AnyObject...) { owners.append(contentsOf: values.map(Owner.init)) }
}
