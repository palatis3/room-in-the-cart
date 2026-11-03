#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI

@MainActor private final class S23DuplicateRequestFixtureState: ObservableObject {
    @Published var model: HouseholdInboxModel?
    @Published var commands = 0
    @Published var failed = false
    private let server = S23DuplicateFixtureServer(pageBoundary:true)
    func start() async {
        guard model == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--request-duplicates-fixture") else { return }
        do {
            server.changed = { [weak self] count in Task { @MainActor in self?.commands = count } }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UITestWorkspace/S23-" + UUID().uuidString)
            model = try await s23DuplicateFixtureModel(server:server,outboxURL:directory.appendingPathComponent("outbox.json"))
        } catch { failed = true }
    }
}

struct S23DuplicateRequestFixtureRoot: View {
    @StateObject private var state = S23DuplicateRequestFixtureState()
    var body: some View {
        VStack {
            S23FixtureCounter(text:"Fixture applied decisions: \(state.commands)",identifier:"fixture.s23.commands")
            if let model = state.model {
                S23DuplicateRequestFixtureContent(model:model)
            } else if state.failed {
                Text("Fixture setup failed").accessibilityIdentifier("fixture.failure")
            } else { ProgressView("Opening isolated S23 fixture") }
        }.task { await state.start() }
    }
}
private struct S23DuplicateRequestFixtureContent: View {
    @ObservedObject var model: HouseholdInboxModel
    var body: some View {
        VStack {
            VStack(spacing:2) {
                S23FixtureCounter(text:"Fixture saved lines: \(model.shop?.lines.count ?? 0)",identifier:"fixture.s23.lines")
                S23FixtureCounter(text:"Fixture loaded requests: \(model.requests.count)",identifier:"fixture.s23.loaded")
            }
            NavigationStack { ShopperInboxContent(model:model).navigationTitle("S23 request comparison") }
        }
    }
}
/// Instrumentation must not consume the product viewport at accessibility sizes.
/// The product NavigationStack keeps the launch's original Dynamic Type setting.
private struct S23FixtureCounter: View {
    let text: String
    let identifier: String
    var body: some View {
        Text(text).font(.system(size:11,design:.monospaced)).dynamicTypeSize(.medium)
            .lineLimit(1).accessibilityIdentifier(identifier)
    }
}
#endif
