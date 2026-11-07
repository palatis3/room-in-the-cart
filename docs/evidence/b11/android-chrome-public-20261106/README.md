# Android Chrome update and public browser checks

The owner completed Play sign-in. Chrome updated through the official Play Store from 149.0.7827.5 to **156.0.8078.79**, installer `com.android.vending`, on the retained Android 14 / API 34 emulator. Google’s version-history response identifies this version as an active stable cohort (79.6% at observation); newer staged releases also exist. This does not claim newest-major coverage.

Actual browser checks passed for Help, Privacy, Terms and Support in both English and Spanish. At 411 CSS pixels all eight pages fit horizontally, keep localized navigation, and produce no captured console/page errors. The support anchor reaches its heading, and the contact link is `hello@roominthecart.com`. No email was sent. Root visually reviewed the Spanish Privacy viewport and English Support anchor viewport.

The invited Requests route correctly reports that email sign-in is unavailable. Switching to Spanish and refreshing preserves that stable state without an unusable sign-in form or horizontal overflow. The final comparison waits for loading to finish; earlier transient-loading and URL-selection probe mistakes are explicitly recorded, not counted as app defects.

These checks cover the public deployed screens and deferred-email state. Authenticated household journeys, provider activation, physical devices, assistive technology and human language acceptance remain separate. Policy pages still identify themselves as drafts. Private Play/account screenshots remain outside Git; only selected public product evidence is retained here.

See [verification](verification.json), [eight-page observations](public-walkthrough.json), and [refresh comparison](requests-es-dom.json).
