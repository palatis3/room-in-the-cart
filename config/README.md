# Native public configuration

`staging.json` supplies Debug and Staging. Release reads only `release.json`; if it is absent, optional connected features and external help/billing destinations remain unconfigured. Release never falls back to staging. Copy `release.example.json` to `release.json` when the owner has the real production values, then regenerate the committed Xcode project with `python3 scripts/generate_xcode_project.py`. These files and generated settings are public; keep server keys, passwords, signing material and App Store API keys elsewhere.

| JSON key | Compiled app key | Owner-supplied value |
| --- | --- | --- |
| `environment` | — | `staging` or `production`, matching the file |
| `emailOTPEnabled` | `RITCEmailOTPEnabled` | Boolean; enable only after the provider's code delivery is verified |
| `supabaseURL` | `SupabaseProjectURL` | That environment's identity project URL |
| `publishableKey` | `SupabasePublishableKey` | Public publishable key, never a service-role key |
| `serviceURL` | `HouseholdServiceURL` | That environment's HTTPS service origin |
| `householdSubscriptionProductID` | `HouseholdSubscriptionProductID` | Permanent Apple product ID for the signed app and service environment |
| `privacyPolicyURL` | `PrivacyPolicyURL` | Operator-approved public HTTPS privacy policy |
| `termsOfUseURL` | `TermsOfUseURL` | Operator-approved public HTTPS purchase/use terms |
| `supportURL` | `SupportURL` | Operator-owned public HTTPS support destination |
| `helpURL` | `HelpURL` | Optional public HTTPS help page; native help works offline |

Page URLs reject credentials, unresolved variables and test/example hosts. Empty values stay visibly unavailable. The build also records `RITCBuildEnvironment` for the reviewed support summary. Existing staging `/help`, `/privacy`, `/terms` and `/support` routes returned 404 on 2026-11-03, so they have not been configured as working pages. No support email or public policy is invented by the app.

The source now includes bilingual public information pages for those four paths in `web/src/public-pages*`, with an intentionally unset monitored contact in `web/src/public-site-configuration.ts`. They are built/tested locally and explicitly disclose unfinished operator policy/terms, retention and human-language review. Publishing those sources and approving the release pages remain separate owner steps; their existence in source does not make a configured native URL operational.

Run `python3 scripts/test_app_configuration.py` for environment-isolation and metadata checks. After building, run `python3 scripts/check_built_app.py /absolute/path/RoomInTheCart.app --configuration Release`. Add `--require-release-metadata` when the operator has supplied the product ID and support/privacy/terms pages. The extra flag verifies metadata presence and HTTPS shape; it does not establish publication, legal review, signed distribution, actual StoreKit purchase, provider setup or App Store acceptance.
