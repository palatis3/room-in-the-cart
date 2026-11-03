import XCTest
@testable import RoomInTheCart

final class HelpConfigurationTests: XCTestCase {
    func testHelpPagesRequireLiteralHTTPSWithoutCredentialsOrTestHosts() {
        XCTAssertNotNil(HelpConfiguration.pageURL("https://support.grocery-app.com/es/help?language=es#account"))
        for value in ["", "http://support.grocery-app.com", "https://user:secret@support.grocery-app.com", "https://localhost/help", "https://example.com/help", "https://support.invalid", "https://support.test", "$(RITC_SUPPORT_URL)", " https://support.grocery-app.com"] {
            XCTAssertNil(HelpConfiguration.pageURL(value), value)
        }
        XCTAssertNil(HelpConfiguration.pageURL(nil))
    }

    func testSupportSummaryAllowlistCannotIncludeArbitraryBundleData() throws {
        let bundle = try testBundle([
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42", "RITCBuildEnvironment": "Staging",
            "HouseholdServiceURL": "https://service.grocery-app.com", "HouseholdSubscriptionProductID": "app.household.annual",
            "PrivacyPolicyURL": "https://grocery-app.com/privacy", "TermsOfUseURL": "https://grocery-app.com/terms",
            "SupabasePublishableKey": "secret-key-marker", "SupportURL": "https://support.grocery-app.com/private-marker",
            "householdName": "Private family marker", "grocery": "Private grocery marker", "budget": "$38.00"
        ])
        let summary = SupportDiagnostics(bundle: bundle, systemVersion: "17.0", language: "es-US").text
        XCTAssertEqual(summary, """
        Room in the Cart
        diagnostic-format: 1
        app-version: 0.1.0
        app-build: 42
        system: iOS 17.0
        interface-language: es-US
        build-environment: Staging
        household-service-configured: true
        membership-configured: true
        """)
        for privateValue in ["secret-key-marker", "private-marker", "Private family marker", "Private grocery marker", "$38.00", "service.grocery-app.com"] {
            XCTAssertFalse(summary.contains(privateValue))
        }
    }

    func testMissingConfigurationStaysUnavailableAndSummaryRejectsInjectedLines() throws {
        let bundle = try testBundle(["CFBundleVersion": "1\nprivate-data", "RITCBuildEnvironment": "Production\nprivate-data"])
        let pages = HelpConfiguration.fromBundle(bundle)
        XCTAssertNil(pages.helpURL); XCTAssertNil(pages.supportURL)
        XCTAssertNil(pages.privacyURL); XCTAssertNil(pages.termsURL)
        let diagnostics = SupportDiagnostics(bundle: bundle, systemVersion: "17.0\nprivate-data", language: "en\nprivate-data")
        XCTAssertFalse(diagnostics.householdConfigured)
        XCTAssertFalse(diagnostics.membershipConfigured)
        XCTAssertEqual(diagnostics.appBuild, "unknown")
        XCTAssertEqual(diagnostics.systemVersion, "unknown")
        XCTAssertEqual(diagnostics.language, "unknown")
        XCTAssertEqual(diagnostics.environment, "unknown")
        XCTAssertFalse(diagnostics.text.contains("private-data"))
    }

    private func testBundle(_ values: [String: Any]) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var info = values
        info["CFBundleIdentifier"] = "test.help." + UUID().uuidString
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(path: directory.path))
    }
}
