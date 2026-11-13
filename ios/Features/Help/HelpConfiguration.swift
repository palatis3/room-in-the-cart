import Foundation

/// Only deployment-owned HTTPS pages may be opened from Help. Missing metadata
/// stays unavailable; neither a guessed domain nor a test destination is used.
struct HelpConfiguration: Equatable, Sendable {
    let helpURL: URL?
    let privacyURL: URL?
    let termsURL: URL?
    let supportURL: URL?
    let supportEmailURL: URL?
    let operatorName: String?
    var supportEmailAddress: String? { supportEmailURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path } }

    static func fromBundle(_ bundle: Bundle = .main, language: String = Bundle.main.preferredLocalizations.first ?? "en") -> Self {
        let service = pageURL(bundle.object(forInfoDictionaryKey: "HouseholdServiceURL") as? String)
        func page(_ key: String) -> URL? {
            guard let url = pageURL(bundle.object(forInfoDictionaryKey: key) as? String) else { return nil }
            // The companion's four public routes accept a language override.
            // An explicit query or another operator-owned site has its own URL contract.
            guard let service, url.host?.lowercased() == service.host?.lowercased(),
                  (url.port ?? 443) == (service.port ?? 443),
                  ["/help", "/support", "/privacy", "/terms"].contains(url.path),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.percentEncodedQuery == nil else { return url }
            let spanish = Locale(identifier: language).language.languageCode?.identifier == "es"
            components.queryItems = [URLQueryItem(name: "lang", value: spanish ? "es" : "en")]
            return components.url
        }
        return Self(helpURL: page("HelpURL"), privacyURL: page("PrivacyPolicyURL"),
                    termsURL: page("TermsOfUseURL"), supportURL: page("SupportURL"),
                    supportEmailURL: emailURL(bundle.object(forInfoDictionaryKey: "SupportEmail") as? String),
                    operatorName: displayOperatorName(bundle.object(forInfoDictionaryKey: "OperatorName") as? String))
    }

    static func displayOperatorName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.utf8.count <= 300, !raw.contains("$("),
              !raw.unicodeScalars.contains(where: {
                  [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
              }) else { return nil }
        return raw
    }

    /// A bare ASCII address only: no subject/body/headers, percent escapes or
    /// newline characters can be added to the mail composer destination.
    static func emailURL(_ raw: String?) -> URL? {
        guard let raw, raw.utf8.count <= 254,
              raw.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$", options: .regularExpression) != nil else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count <= 64, !parts[0].hasSuffix("."), !parts[0].contains(".."),
              parts[1].split(separator: ".").allSatisfy({ $0.utf8.count <= 63 }),
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return URL(string: "mailto:" + raw)
    }

    static func pageURL(_ raw: String?) -> URL? {
        guard let raw, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.contains("$("),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https", let rawHost = components.host,
              case let host = rawHost.lowercased(),
              !host.isEmpty, components.user == nil, components.password == nil,
              host != "localhost", !host.hasSuffix(".invalid"), !host.hasSuffix(".test"),
              !["example.com", "example.org", "example.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              let url = components.url else { return nil }
        return url
    }
}

/// Constructed exclusively from public application/runtime metadata. It has no
/// store, household, error, log, receipt, URL, credential or user-content input.
struct SupportDiagnostics: Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let systemVersion: String
    let language: String
    let environment: String
    let householdConfigured: Bool
    let membershipConfigured: Bool

    init(bundle: Bundle = .main, systemVersion: String, language: String) {
        func numeric(_ raw: Any?) -> String {
            guard let value = raw as? String, !value.isEmpty, value.count <= 32,
                  value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) }) else { return "unknown" }
            return value
        }
        appVersion = numeric(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        appBuild = numeric(bundle.object(forInfoDictionaryKey: "CFBundleVersion"))
        self.systemVersion = numeric(systemVersion)
        let codeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        self.language = !language.isEmpty && language.count <= 32 && language.unicodeScalars.allSatisfy(codeCharacters.contains) ? language : "unknown"
        let configuredEnvironment = bundle.object(forInfoDictionaryKey: "RITCBuildEnvironment") as? String
        environment = ["Debug", "Staging", "Release"].contains(configuredEnvironment ?? "") ? configuredEnvironment! : "unknown"
        householdConfigured = HelpConfiguration.pageURL(bundle.object(forInfoDictionaryKey: "HouseholdServiceURL") as? String) != nil
        membershipConfigured = MembershipConfiguration.fromBundle(bundle).isReady
    }

    /// Fixed machine-readable labels also keep the shared content auditable
    /// across interface languages. The complete summary is previewed first.
    var text: String {
        """
        Room in the Cart
        diagnostic-format: 1
        app-version: \(appVersion)
        app-build: \(appBuild)
        system: iOS \(systemVersion)
        interface-language: \(language)
        build-environment: \(environment)
        household-service-configured: \(householdConfigured)
        membership-configured: \(membershipConfigured)
        """
    }
}
