import DeviceSurfaces
import Foundation

enum PrivateReceiptInbox {
    static func open() throws -> SharedCaptureInbox {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG && targetEnvironment(simulator)
        if SurfaceRuntimeIsolation.usesUITestWorkspace(launchArguments: arguments),
           let index = arguments.firstIndex(of: "--receipt-share-test-store"), index + 1 < arguments.count {
            return try ReceiptShareSystemFixture.open(token: arguments[index + 1], now: Date())
        }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try SurfaceRuntimeIsolation(directory: nil, launchArguments: arguments, applicationSupport: support)
            .makeReceiptInbox { try IOSSurfaceContainers.sharedCaptures() }
    }
    static func expireOnForeground() async throws {
        guard !SurfaceRuntimeIsolation.usesUITestWorkspace(launchArguments: ProcessInfo.processInfo.arguments) else { return }
        try await IOSSurfaceContainers.expireExistingSharedReceipts()
    }
}
