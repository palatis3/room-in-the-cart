# Native public configuration

`public-contact.json` supplies the user-provided operator business, **Venture House Group LLC**, and public support address, `hello@roominthecart.com`, to all native environments. An environment can explicitly override or blank `operatorName` or `supportEmail`. No email is sent by configuration. `staging.json` supplies Debug and Staging. `release.json` supplies Release. If it is absent, optional connected features and external help/billing destinations remain unconfigured. Copy `release.example.json` to `release.json` when the owner has the real production values, then regenerate the committed Xcode project with `python3 scripts/generate_xcode_project.py`. These files and generated settings are public; keep server keys, passwords, signing material and App Store API keys elsewhere.

Xcode’s RoomInTheCart-Staging scheme runs, tests, profiles and archives the staging bundle. Its test action checks the deployed service anonymously and opens the published Help and Support pages from the native app. Use an internet-connected iPhone simulator with Safari for those checks. An internal TestFlight build can use this staging scheme and its own App Store Connect bundle record once distribution signing is configured. The RoomInTheCart scheme runs the ordinary Debug suites.

| JSON key | Compiled app key | Owner-supplied value |
| --- | --- | --- |
| `environment` | — | `staging` or `production`, matching the file |
| `regionalAgeCheckEnabled` | `RITCRegionalAgeCheckEnabled` | Optional boolean. Enables the native regional check and selects the app entitlement for this build. Defaults to false. |
| `emailOTPEnabled` | `RITCEmailOTPEnabled` | Boolean; enable only after the provider's code delivery is verified |
| `supabaseURL` | `SupabaseProjectURL` | That environment's identity project URL |
| `publishableKey` | `SupabasePublishableKey` | Public publishable key, never a service-role key |
| `serviceURL` | `HouseholdServiceURL` | That environment's HTTPS service origin |
| `householdSubscriptionProductID` | `HouseholdSubscriptionProductID` | Permanent Apple product ID for the signed app and service environment |
| `privacyPolicyURL` | `PrivacyPolicyURL` | Operator-approved public HTTPS privacy policy |
| `termsOfUseURL` | `TermsOfUseURL` | Operator-approved public HTTPS purchase/use terms |
| `supportURL` | `SupportURL` | Operator-owned public HTTPS support page for distribution |
| `supportEmail` | `SupportEmail` | Bare support address; defaults to the supplied address in `public-contact.json` |
| `operatorName` | `OperatorName` | Supplied business name, Venture House Group LLC; literal text without control/format characters |
| `publicWebsiteURL` | `PublicWebsiteURL` | Optional HTTPS origin of the operator’s first-party companion website |
| `helpURL` | `HelpURL` | Optional public HTTPS help page; native help works offline |

To connect the public site before enabling household accounts, set `publicWebsiteURL` in the appropriate environment’s configuration and regenerate the Xcode project. Use the site's HTTPS origin, optionally with a port and trailing slash. Native Help opens the companion’s `/help`, `/support`, `/privacy` and `/terms` pages in the app’s language. The family action opens `/help?lang=es#child-permission` or its English equivalent. An explicit page URL overrides that page; external custom addresses, queries and fragments retain their own routing. Membership still requires explicit operator-approved privacy and terms URLs. With no website configured, an explicitly configured Help page on the household service origin keeps its existing companion behavior; local help remains available with every URL blank.

Configured backend URLs must use HTTPS without credentials, query strings or fragments. Use canonical IP addresses or ASCII hostnames, including punycode for internationalized domains. The native identity client accepts Supabase `sb_publishable_` keys. Release rejects the staging Supabase and household service origins for its backend, Privacy, Terms, Support and Help URLs. It also rejects a reused staging publishable key. Origin comparison normalizes the host and HTTPS port across paths, queries and fragments. Both builds can link to an approved public support or policy site hosted separately from the staging services. Alternate domains can still point to the same deployment, so confirm the actual project and service identities when provisioning production.

Page URLs reject credentials, unresolved variables, malformed ports, private addresses and special-use hosts. Empty values stay visibly unavailable. The build also records `RITCBuildEnvironment` for the reviewed support summary. Staging serves `/help`, `/privacy`, `/terms` and `/support`. The native staging configuration links to Help and Support. For the four companion routes on the household service origin, the iPhone app passes its selected English or Spanish language to the browser. An operator-supplied query string or external destination keeps its configured URL. Production policy and terms URLs await operator review. [IANA special-use names](https://www.iana.org/assignments/special-use-domain-names), [IPv4 address registry](https://www.iana.org/assignments/iana-ipv4-special-registry), [IPv6 address registry](https://www.iana.org/assignments/iana-ipv6-special-registry)

The source now includes bilingual public information pages for those four paths in `web/src/public-pages*`, with the supplied operator business Venture House Group LLC and `mailto:hello@roominthecart.com` contact in `web/src/public-site-configuration.ts`. Operator names reject control/format characters, line separators, unresolved variables, surrounding whitespace and more than 300 UTF-8 bytes. Both native and public contact validators reject whitespace, headers, query/fragment and percent-encoded payloads. The contact opens an email composer without sending. Mailbox delivery has not been tested. The staging deployment serves these pages in English and Spanish. Production publication still requires the operator’s policy, terms, retention and language review. [Staging deployment record](../docs/RELEASE-EXECUTION.md)

Run `python3 scripts/test_app_configuration.py` for environment-isolation and metadata checks. After building, run `python3 scripts/check_built_app.py /absolute/path/RoomInTheCart.app --configuration Release`. To verify an iPhone device archive, pass its `.xcarchive` path and the matching configuration to the same command. It checks the app and embedded extensions against their archived crash symbols. For a production distribution candidate, add `--require-release-metadata`. It requires the production identity URL, publishable client key, household service URL, enabled email-code sign-in, subscription product ID, and public Support, Privacy and Terms URLs. The same check runs before GitHub allocates native runners for release qualification. Verify sign-in, household access, policy publication and StoreKit purchases against their live services before distribution.

## Signed App Store archive and local IPA

Venture House Group LLC uses team `SP7Z9RNC76`. The registered host bundle ID is `dev.roominthecart.app`. The widget and share extensions append `.widget` and `.share`. The host uses both App Groups. Each extension has access to its own group. The distribution profiles grant complete data protection.

On the signing Mac, install the organization's Apple Distribution identity and the three App Store profiles named in [AppStoreExport.plist](AppStoreExport.plist). Download existing profiles in Xcode Settings under Apple Accounts, then select the organization and choose Download Manual Profiles. From the repository root, create the archive and check the production configuration before exporting the IPA locally.

```sh
set -e
archive=".build/app-store/RoomInTheCart.xcarchive"
mkdir -p .build/app-store
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart-Release \
  -configuration Release -destination 'generic/platform=iOS' \
  -xcconfig config/AppStoreDistribution.xcconfig \
  -archivePath "$archive" archive
python3 scripts/check_built_app.py "$archive" --configuration Release \
  --require-distribution-signing --require-release-metadata
xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist config/AppStoreExport.plist -exportPath .build/app-store/export
```

The export uses the version and build number in the archive. Both signing configuration files contain public identifiers and profile names. The private signing key stays in the signing Mac's keychain.

To check the exported signature, extract the IPA with `ditto -x -k` and run the same checker against `Payload/RoomInTheCart.app`. The signed app and each extension must retain their App Groups and data-protection entitlements.

With the Node version from `.node-version` on your path, run `python3 scripts/check_native_backend.py Staging` or `python3 scripts/check_native_backend.py Release` to check the selected build’s public configuration against the deployed Supabase Auth settings, advertised signing keys, service health and email-sign-in availability. This read-only probe sends no email and creates no records. Exercise code delivery, session refresh and a household save and reopen on the signed candidate as a separate check.

For a private TestFlight or App Review environment restricted to pre-created accounts, add `--existing-accounts-only`. The check requires enabled email-code entry in the app and service, disabled public signup, required email confirmation, and email as the only advertised sign-in method. Verify separately that the existing accounts belong to the intended reviewers or testers. Give each reviewer access to the fictional account’s mailbox so they can retrieve fresh codes throughout review.

## Regional age checks

After the owner reviews applicability for the distribution territories, provision the Declared Age Range capability on the **app’s** App ID and refresh its profile. To test, set `regionalAgeCheckEnabled` to `true` in the staging configuration and regenerate the Xcode project. Debug uses the staging configuration. For Release, the same key must be set separately in the local release configuration. The distribution signature verifier checks the enabled app and its profile for the entitlement. Widget and Share extensions keep their existing entitlements.

On iOS 26.4 and later the app checks whether Apple requires age sharing for the current account. On iOS 26.2–26.3 it uses the earlier regional eligibility signal. Earlier versions follow the existing shopping flow. A required check must return a shared range before the shopping window opens. A network failure or an unsuccessful required check offers a retry. The app retains the check outcome in memory until the session backgrounds or the iCloud identity changes. All shared bands reach the same shopping window. The app neither stores nor sends the age range and never uses it to grant a guardian or child role.

Before enabling the feature for distribution, exercise an unaffected account, a covered adult, a covered child, declined sharing, network failure and retry, background/foreground, and an iCloud account change in Apple’s sandbox. Test widget links and the separate adult and child household routes. Verify app launch after a parent revokes consent and delivery of the signed server notification. The owner determines which features require different access by age and which future changes require additional consent before shipping them. [Apple’s age assurance Q&A](https://developer.apple.com/support/age-assurance/) · [Apple’s Declared Age Range framework](https://developer.apple.com/documentation/declaredagerange)
