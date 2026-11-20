#if DEBUG && targetEnvironment(simulator)
import Foundation
import HouseholdClient
import SwiftUI

private struct HouseholdTripFixtureActor: Decodable, Sendable {
    let householdId, deviceId, deviceToken, accessToken, subject: String
}

private final class TripFixtureVault: RefreshTokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func read() throws -> String? { lock.withLock { value } }
    func write(_ next: String) throws { lock.withLock { value = next } }
    func clear() throws { lock.withLock { value = nil } }
}

private final class TripLoopbackPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The synthetic provider and device enrollment exist only here. Every household operation goes through the actual loopback service.
private final class HouseholdTripFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let manifestOrigin = URL(string: "http://127.0.0.1:48761")!
    static let serviceOrigin = URL(string: "http://127.0.0.1:48762")!
    static let appOrigin = URL(string: "https://trip-journey.invalid")!
    static let loopback: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration, delegate: TripLoopbackPolicy(), delegateQueue: nil)
    }()
    private static let lock = NSLock()
    private static var actor: HouseholdTripFixtureActor?
    private static var offline = false
    static func bind(_ value: HouseholdTripFixtureActor) { lock.withLock { actor = value; offline = false } }
    static func setOffline(_ value: Bool) { lock.withLock { offline = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var forwardedTask: URLSessionDataTask?

    override func startLoading() {
        do {
            let (actor, offline) = Self.lock.withLock { (Self.actor, Self.offline) }
            guard let url = request.url, url.host == Self.appOrigin.host, let actor else { throw URLError(.unsupportedURL) }
            if offline { throw URLError(.notConnectedToInternet) }
            let user = ["id": actor.subject, "email_confirmed_at": "2026-01-01T00:00:00Z"]
            let reply: [String: Any]?
            switch url.path {
            case "/auth/v1/verify", "/auth/v1/token":
                reply = ["access_token": actor.accessToken, "refresh_token": "fixture-only", "expires_in": 3600, "user": user]
            case "/auth/v1/user": reply = user
            case "/v1/households/" + actor.householdId + "/devices":
                reply = ["deviceId": actor.deviceId, "deviceToken": actor.deviceToken]
            default: reply = nil
            }
            if let reply {
                finish(status: 200, data: try JSONSerialization.data(withJSONObject: reply))
                return
            }
            guard url.path.hasPrefix("/v1/"), var local = URLComponents(url: Self.serviceOrigin, resolvingAgainstBaseURL: false),
                  let original = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.unsupportedURL) }
            local.percentEncodedPath = original.percentEncodedPath
            local.percentEncodedQuery = original.percentEncodedQuery
            var forwarded = request
            forwarded.url = local.url
            if let stream = forwarded.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count < 0 { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    data.append(bytes, count: count)
                }
                forwarded.httpBody = data
            }
            forwardedTask = Self.loopback.dataTask(with: forwarded) { [weak self] data, response, error in
                guard let self else { return }
                if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
                guard let status = (response as? HTTPURLResponse)?.statusCode else {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                self.finish(status: status, data: data ?? Data())
            }
            forwardedTask?.resume()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { forwardedTask?.cancel() }
    private func finish(status: Int, data: Data) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                                    headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

struct HouseholdTripFixture: View {
    let notificationDelegate: SurfaceNotificationDelegate
    @State private var household: HouseholdModel?
    @State private var failed = false
    @State private var offline = false

    var body: some View {
        Group {
            if let household {
                GroceryWindow(notificationDelegate: notificationDelegate, household: household)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if ProcessInfo.processInfo.arguments.contains("--trip-offline-controls") {
                            Toggle("Fixture offline", isOn: $offline)
                                .accessibilityIdentifier("fixture.trip.offline")
                                .onChange(of: offline) { _, value in HouseholdTripFixtureProtocol.setOffline(value) }
                                .padding(.horizontal).background(.bar)
                        }
                    }
            } else if failed {
                ContentUnavailableView {
                    Label("Local trip fixture unavailable", systemImage: "network.slash")
                } actions: {
                    Button("Retry local fixture") { Task { await start() } }
                }
            } else { ProgressView().task { await start() } }
        }
    }

    private func start() async {
        do {
            let role = ProcessInfo.processInfo.arguments.contains("--trip-shopper") ? "shopper" : "requester"
            let manifest = HouseholdTripFixtureProtocol.manifestOrigin.appendingPathComponent("fixture/" + role)
            let (bytes, response) = try await HouseholdTripFixtureProtocol.loopback.data(from: manifest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientError.invalidResponse }
            let actor = try JSONDecoder().decode(HouseholdTripFixtureActor.self, from: bytes)
            guard UUID(uuidString: actor.householdId) != nil, UUID(uuidString: actor.deviceId) != nil else { throw ClientError.invalidResponse }
            HouseholdTripFixtureProtocol.bind(actor)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HouseholdTripFixtureProtocol.self]
            let transport = HTTPTransport(session: URLSession(configuration: configuration))
            let origin = HouseholdTripFixtureProtocol.appOrigin
            let auth = AdultAuth(configuration: try .init(projectURL: origin, publishableKey: "sb_publishable_trip_fixture"),
                                 vault: TripFixtureVault(), transport: transport)
            let service = HouseholdService(configuration: try .init(baseURL: origin), auth: auth, deviceVault: TripFixtureVault(), transport: transport)
            let store = FileManager.default.temporaryDirectory.appendingPathComponent("TripFixture/" + actor.householdId + "/" + actor.deviceId + "/outbox.json")
            let model = HouseholdModel(auth: auth, service: service, outboxURL: store, deletionVault: TripFixtureVault(),
                                       exitVault: TripFixtureVault(), guardianVault: TripFixtureVault())
            model.email = role + "@example.invalid"; model.code = "123456"
            await model.verifyCode()
            guard let workspace = model.workspaces.first(where: { $0.householdId == actor.householdId }) else { throw ClientError.invalidResponse }
            model.keepLocalPrivate = true
            await model.join(workspace)
            guard model.projection?.capabilities.contains("shared_picking") == true else { throw ClientError.accessEnded }
            failed = false
            household = model
        } catch { failed = true }
    }
}
#endif
