# Connect roominthecart.com to the iPhone app

**Owner milestone · When the public website is ready.** Give the person preparing the next build the final HTTPS address and confirm that the English and Spanish support and policy text is approved for publication. The project already contains these pages. The proposed canonical address below assumes `https://roominthecart.com`. Use the actual final hostname if it includes `www`.

| Destination | Proposed path | How to verify |
| --- | --- | --- |
| Product overview | `/about` | Open signed out on a phone. Verify the app screenshots and support link. |
| Family help in English | `/help?lang=en#child-permission` | The child and guardian section opens in English. |
| Family help in Spanish | `/help?lang=es#child-permission` | The section opens in Spanish and explains what the child may request, who gives permission and how to get help joining. |
| Support | `/support` | The public support address is `hello@roominthecart.com`. The page opens without signing in. |
| Privacy and terms | `/privacy` and `/terms` | Both pages open directly on an iPhone. Confirm the text describes the features and data practices in the release. |

## Release handoff

1. Publish the approved public pages to the canonical domain when the owner chooses. Verify HTTPS, direct links, and both languages using a signed-out browser. Check the visible section after loading the family URL. An HTTP 200 response alone also occurs when a website sends every path to its homepage.
2. In the app repo, create or update `config/release.json` using [the release example](../config/release.example.json) and [native public configuration](../config/README.md). Set `publicWebsiteURL` to the final HTTPS origin, for example `"publicWebsiteURL": "https://roominthecart.com"`. Use the origin only, with no path, query, or fragment. The standard same-site paths are `/help`, `/support`, `/privacy` and `/terms`. Set explicit `helpURL`, `supportURL`, `privacyPolicyURL` or `termsOfUseURL` overrides for different approved destinations. Public help can be configured independently of household sign-in, email, database and billing setup.
3. Regenerate the project with `python3 scripts/generate_xcode_project.py`. Verify it with `python3 scripts/generate_xcode_project.py --check` and run the configuration and localization checks. Build an iPhone Release candidate and inspect the actual public URLs in its compiled Info.plist. Use the deployed matching family section when exercising the Staging qualification.
4. From an existing list with two unchecked groceries, open the family guide in English and Spanish. Open the public guide inside the app, read the child-permission section, tap Done and return to the same list. Verify both groceries and their unchecked state. Repeat on a compact iPhone with large text. Also open Support, Privacy and Terms. Record the candidate build, website version, URLs, and observed return. Leave the original offline-only benchmark attributed to its build.
5. When preparing the listing, use the verified `/support` address as the Support URL, the approved `/privacy` address for the Privacy Policy URL and the approved product page for the optional Marketing URL. Update any draft metadata that still points to an earlier address. Website publication, signing or uploading a build and submitting it for App Review are separate owner decisions. [Apple’s version and support URL fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) · [Apple’s privacy policy field](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)

A public address is compiled into the signed app. Sign a new build to distribute changed app addresses or new native navigation. Once the addresses in a distributed build are stable, wording, screenshots and support articles on those pages can be updated on the website. Retain existing routes, query parameters and the `child-permission` anchor when revising the site.
