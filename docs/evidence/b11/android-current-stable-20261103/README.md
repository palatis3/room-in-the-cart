# Current Android Chrome acquisition — November 3, 2026

**Current-browser acceptance: UNRUN. No current Android Chrome package was acquired.** The bounded official-source check finished at **2026-11-03 21:52:00 UTC**. Historical Chrome113/149 evidence remains separate and cannot satisfy this gate.

[Google's active Android stable API](https://versionhistory.googleapis.com/v1/chrome/platforms/android/channels/stable/versions/all/releases?filter=endtime%3Dnone&order_by=version%20desc&pageSize=20) returned only **156.0.8078.79**, fraction1, serving since2026-11-03T19:37:07.452381Z with no end time. The raw371-byte response is included as `active-android-stable.json`.

| Official route | Bounded observation |
|---|---|
| [Android download page](https://www.google.com/chrome/android/), [Chromium release channels](https://www.chromium.org/getting-involved/chrome-release-channels/), [Android installation documentation](https://developer.chrome.com/docs/chromedriver/get-started/android) | Stable Android links point to Google Play's `com.android.chrome` listing. No standalone APK link was found in the fetched consumer download source. |
| [Public Play SDK metadata](https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml) | HTTP200 and byte-identical to the prior inventory, SHA256 `515d4f4d418b580db9f48ec0f4dcc3fb1fada378f3a49b289b9adffda3a3d079`. No new package entry. Prior independent inspection of image37.2r07 found Chrome149.0.7827.5; that image was not downloaded or inspected again here. |
| Official signed stable archive | Anonymous HEAD to the derived candidate `https://storage.googleapis.com/chrome-signed/android-B0urB0N/156.0.8078.79/arm_64/ChromeStable.apks` returned HTTP403 at21:52:00UTC. No package body downloaded. A403 does not establish object existence. |
| [Chrome for Testing platform matrix](https://github.com/GoogleChromeLabs/chrome-for-testing#supported-platforms) | Linux, macOS and Windows platforms only; no Android artifact. |
| [Chrome Enterprise download page](https://chromeenterprise.google/browser/download/) | No APK link found in the fetched public source. No account or management setup attempted. |

Seven official-source GETs succeeded, totaling1,580,663bytes, with a3MB per-response cap and at most three concurrent requests. `source-provenance.json` records their exact URLs, response dates, byte counts and SHA256 hashes. HTML/XML bodies remain in the original scratch evidence and are intentionally omitted from this compact repository report. The signed candidate HEAD result is included separately. `acquisition-status.json` records the exact scope, while `preservation-manifest.json` hashes all other installed files.

The remaining prerequisite is a permitted official Google-signed current stable Android package, or an authorized test Android device already running a verified current stable version. An artifact's exact source/version/size must be reported before download, then its manifest, signer, ABI and minSDK verified before installation. These checks found no new permitted account-free artifact among the inspected routes; they do not prove universal unavailability.

No APK/image download, SDK mutation, emulator boot, ADB or simulator action, personal Google account/login, terms acceptance, payment, email, provider action or system Java change occurred. The root's earlier working browser exposed an existing personal Google account on Play; no account/device controls were used, and this check did not access that session. The prior automatic approval rejection of a2.26GB canary image download remains respected: no retry, bypass or canary substitution occurred. No current package manifest/signature/install/launch or browser journey was verified.

This report installation adds evidence only. Existing historical113/149 documents are unchanged. No Git action was performed.
