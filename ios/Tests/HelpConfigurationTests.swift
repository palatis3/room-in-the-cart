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

    func testAppLanguageFollowsCompanionLinksAndPreservesOperatorDestinations() throws {
        let bundle = try testBundle([
            "HouseholdServiceURL": "https://grocery-app.com",
            "HelpURL": "https://grocery-app.com:443/help#public-section-1",
            "SupportURL": "https://support.grocery-app.com/support",
            "PrivacyPolicyURL": "https://grocery-app.com/privacy?lang=en",
            "TermsOfUseURL": "https://grocery-app.com:8443/terms"
        ])
        let spanish = HelpConfiguration.fromBundle(bundle, language: "es-US")
        XCTAssertEqual(spanish.helpURL?.absoluteString, "https://grocery-app.com:443/help?lang=es#public-section-1")
        XCTAssertEqual(spanish.supportURL?.absoluteString, "https://support.grocery-app.com/support")
        XCTAssertEqual(spanish.privacyURL?.absoluteString, "https://grocery-app.com/privacy?lang=en")
        XCTAssertEqual(spanish.termsURL?.absoluteString, "https://grocery-app.com:8443/terms")
        XCTAssertEqual(HelpConfiguration.fromBundle(bundle, language: "en-US").helpURL?.query, "lang=en")
        XCTAssertEqual(MembershipConfiguration.fromBundle(bundle).privacyURL, spanish.privacyURL)
    }

    func testPublicWebsiteAloneLocalizesHelpAndFamilyWithoutActivatingHouseholdOrBilling() throws {
        let origin = "https://family.grocery-app.com:8443"
        let bundle = try testBundle(["PublicWebsiteURL": origin + "/", "HouseholdSubscriptionProductID": "family.annual"])
        for (locale, language) in [("es-MX", "es"), ("en-US", "en")] {
            let config = HelpConfiguration.fromBundle(bundle, language: locale)
            XCTAssertEqual(config.helpURL?.absoluteString, origin + "/help?lang=" + language)
            XCTAssertEqual(config.familyHelpURL?.absoluteString, origin + "/help?lang=" + language + "#child-permission")
            XCTAssertEqual(config.supportURL?.absoluteString, origin + "/support?lang=" + language)
            XCTAssertEqual(config.privacyURL?.absoluteString, origin + "/privacy?lang=" + language)
            XCTAssertEqual(config.termsURL?.absoluteString, origin + "/terms?lang=" + language)
        }
        let diagnostics = SupportDiagnostics(bundle: bundle, systemVersion: "17", language: "es")
        XCTAssertFalse(diagnostics.householdConfigured)
        XCTAssertFalse(diagnostics.membershipConfigured)
        XCTAssertFalse(MembershipConfiguration.fromBundle(bundle).isReady)
    }

    func testExplicitWebsiteKeepsCustomDocumentsAndUsesItsOwnOriginsFamilyGuide() throws {
        let docs = "https://docs.grocery-app.com/help?lang=fr&topic=a%2Fb#families"
        let policy = "https://legal.grocery-app.com/privacy?document=current#read"
        let terms = "https://family.grocery-app.com/terms?v=2#one"
        let bundle = try testBundle(["PublicWebsiteURL": "https://family.grocery-app.com",
            "HouseholdServiceURL": "https://api.grocery-app.com", "HelpURL": docs,
            "PrivacyPolicyURL": policy, "TermsOfUseURL": terms, "SupportURL": "https://api.grocery-app.com/support"])
        let config = HelpConfiguration.fromBundle(bundle, language: "es")
        XCTAssertEqual(config.helpURL?.absoluteString, docs)
        XCTAssertEqual(config.privacyURL?.absoluteString, policy)
        XCTAssertEqual(config.termsURL?.absoluteString, terms)
        XCTAssertEqual(config.supportURL?.absoluteString, "https://api.grocery-app.com/support")
        XCTAssertEqual(config.familyHelpURL?.absoluteString, "https://family.grocery-app.com/help?lang=es#child-permission")
    }

    func testMissingOrMalformedWebsiteDoesNotInventPublicDestinations() throws {
        for origin in ["", "http://family.grocery-app.com", "https://user@family.grocery-app.com",
                       "https://family.grocery-app.com/help", "https://family.grocery-app.com/?", "https://family.grocery-app.com/#operator"] {
            let config = HelpConfiguration.fromBundle(try testBundle(["PublicWebsiteURL": origin]))
            XCTAssertNil(config.helpURL, origin)
            XCTAssertNil(config.familyHelpURL, origin)
        }
        let config = HelpConfiguration.fromBundle(try testBundle(["PublicWebsiteURL": "https://family.grocery-app.com",
            "HelpURL": "http://docs.grocery-app.com/help"]))
        XCTAssertNil(config.helpURL)
    }

    func testSupportSiteUsesAppLanguageOnlyForItsPublishedPages() throws {
        let site = "https://customer.grocery-app.com"
        let values = ["SupportPagesOrigin": site, "PrivacyPolicyURL": site + "/privacy", "SupportURL": site + "/support"]
        let bundle = try testBundle(values)
        for (appLanguage, query) in [("es-MX", "es"), ("en-US", "en")] {
            let config = HelpConfiguration.fromBundle(bundle, language: appLanguage)
            XCTAssertEqual(config.privacyURL?.absoluteString, site + "/privacy?lang=" + query)
            XCTAssertEqual(config.supportURL?.absoluteString, site + "/support?lang=" + query)
            XCTAssertNil(config.helpURL)
            XCTAssertNil(config.familyHelpURL)
            XCTAssertNil(config.termsURL)
        }
        for custom in [site + "/support?ref=help", site + "/support#contact", site + "/other",
                       "https://other.grocery-app.com/support", "https://customer.grocery-app.com:8443/support"] {
            var overrides = values
            overrides["SupportURL"] = custom
            let config = HelpConfiguration.fromBundle(try testBundle(overrides), language: "es")
            XCTAssertEqual(config.supportURL?.absoluteString, custom)
        }
    }

    func testFamilyGuideUsesOnlyTheConfiguredCompanionHelpAddress() throws {
        let base = ["HouseholdServiceURL": "https://grocery-app.com", "HelpURL": "https://grocery-app.com/help"]
        let bundle = try testBundle(base)
        for language in ["en", "es"] {
            XCTAssertEqual(HelpConfiguration.fromBundle(bundle, language: language).familyHelpURL?.absoluteString,
                           "https://grocery-app.com/help?lang=\(language)#child-permission")
        }
        for help in ["https://operator.grocery-app.com/help", "https://grocery-app.com/help#operator",
                     "https://grocery-app.com/help?topic=contact"] {
            var custom = base
            custom["HelpURL"] = help
            let configuration = HelpConfiguration.fromBundle(try testBundle(custom), language: "es")
            XCTAssertNil(configuration.familyHelpURL)
            XCTAssertNotNil(configuration.helpURL)
        }
    }

    func testBareSupportEmailOpensOnlyAddressWithoutHeadersOrEncodedPayload() throws {
        let contact = try XCTUnwrap(HelpConfiguration.emailURL("hello@roominthecart.com"))
        XCTAssertEqual(contact.absoluteString, "mailto:hello@roominthecart.com")
        let components = try XCTUnwrap(URLComponents(url: contact, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "hello@roominthecart.com")
        XCTAssertNil(components.query); XCTAssertNil(components.fragment)
        for value in ["hello@roominthecart.com\nBcc:other@roominthecart.com", "hello@roominthecart.com?subject=hello", "hello%0d%0a@roominthecart.com", "mailto:hello@roominthecart.com", "hello@roominthecart.com#body", " hello@roominthecart.com", "hello..other@roominthecart.com", "hello@-roominthecart.com", "hello@roominthecart..com", "hello@roominthecart.com\r"] {
            XCTAssertNil(HelpConfiguration.emailURL(value), value)
        }
        let bundle = try testBundle(["SupportEmail": "hello@roominthecart.com"])
        XCTAssertEqual(HelpConfiguration.fromBundle(bundle).supportEmailAddress, "hello@roominthecart.com")
        XCTAssertNil(HelpConfiguration.fromBundle(bundle).supportURL)
    }

    func testSuppliedOperatorNameIsPreservedAndRejectsControlOrFormatCharacters() throws {
        XCTAssertEqual(HelpConfiguration.displayOperatorName("Venture House Group LLC"), "Venture House Group LLC")
        for value in ["", " Venture House Group LLC", "Venture House Group LLC ", "Venture\nHouse Group LLC", "Venture\tHouse Group LLC", "Venture\0House Group LLC", "Venture\u{202e}House Group LLC", "Venture\u{2028}House Group LLC", "$(OPERATOR_NAME)", String(repeating: "a", count: 301)] {
            XCTAssertNil(HelpConfiguration.displayOperatorName(value), value)
        }
        XCTAssertNil(HelpConfiguration.displayOperatorName(nil))
        let bundle = try testBundle(["OperatorName": "Venture House Group LLC", "SupportEmail": "hello@roominthecart.com"])
        let configuration = HelpConfiguration.fromBundle(bundle)
        XCTAssertEqual(configuration.operatorName, "Venture House Group LLC")
        XCTAssertEqual(configuration.supportEmailAddress, "hello@roominthecart.com")
    }

    func testSupportSummaryAllowlistCannotIncludeArbitraryBundleData() throws {
        let bundle = try testBundle([
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42", "RITCBuildEnvironment": "Staging",
            "HouseholdServiceURL": "https://service.grocery-app.com", "HouseholdSubscriptionProductID": "app.household.annual",
            "PrivacyPolicyURL": "https://grocery-app.com/privacy", "TermsOfUseURL": "https://grocery-app.com/terms",
            "SupabasePublishableKey": "secret-key-marker", "SupportURL": "https://support.grocery-app.com/private-marker",
            "SupportEmail": "hello@roominthecart.com",
            "OperatorName": "Venture House Group LLC",
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
        for privateValue in ["secret-key-marker", "private-marker", "Private family marker", "Private grocery marker", "$38.00", "service.grocery-app.com", "hello@roominthecart.com", "Venture House Group LLC"] {
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
