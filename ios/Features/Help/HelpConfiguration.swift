import Foundation

/// Only deployment-owned HTTPS pages may be opened from Help. Missing metadata
/// stays unavailable; neither a guessed domain nor a test destination is used.
struct HelpConfiguration: Equatable, Sendable {
    let helpURL: URL?
    let privacyURL: URL?
    let termsURL: URL?
    let supportURL: URL?

    static func fromBundle(_ bundle: Bundle = .main) -> Self {
        Self(helpURL: pageURL(bundle.object(forInfoDictionaryKey: "HelpURL") as? String),
             privacyURL: pageURL(bundle.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String),
             termsURL: pageURL(bundle.object(forInfoDictionaryKey: "TermsOfUseURL") as? String),
             supportURL: pageURL(bundle.object(forInfoDictionaryKey: "SupportURL") as? String))
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
