#if STAGING
import Foundation
import XCTest

final class StagingServiceTests: XCTestCase {
    func testInstalledAppReachesItsStagingServiceAnonymously() async throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.bundleIdentifier, "dev.roominthecart.app.staging")
        let origin = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "HouseholdServiceURL") as? String)
        XCTAssertEqual(origin, "https://room-in-the-cart-staging.vercel.app")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "HelpURL") as? String, origin + "/help")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SupportURL") as? String, origin + "/support")
        let otpSetting = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "RITCEmailOTPEnabled"))
        let emailEnabled = (otpSetting as? NSNumber)?.boolValue ?? (otpSetting as? NSString)?.boolValue
        XCTAssertNotNil(emailEnabled)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for (path, expectedStatus) in [("/health", 200), ("/v1/auth/session", 200), ("/v1/me/workspaces", 401)] {
            let url = try XCTUnwrap(URL(string: origin + path))
            let (data, response) = try await session.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.url, url)
            XCTAssertEqual(http.statusCode, expectedStatus, path)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store", path)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if path == "/health" {
                XCTAssertEqual(body["status"] as? String, "running")
            }
            if path == "/v1/auth/session" {
                XCTAssertEqual(body["authenticated"] as? Bool, false)
                XCTAssertEqual(body["available"] as? Bool, emailEnabled)
            }
        }
    }
}
#endif
