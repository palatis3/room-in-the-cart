# US storefront and keyword-targeted product pages

## Launch decision

Prepare **one iPhone app record, one country, two localizations and three page designs**. US English is the primary localization. Spanish (Mexico) serves Spanish-language shoppers in the United States. Use the default product page for the first release. Prepare the two additional designs locally and apply for custom page review after the app reaches Ready for Distribution.

Three independent reviews recommended between four and six distinct screenshots per language. Aim for five where the fifth teaches a different task. A pack comparison screen and a mostly empty saved-record screen demonstrate the same feature. The latter belongs in the verification packet. Use direct, language-matched captures with natural fictional food names, genuine calculations and a clean status bar. [Apple storefront localizations](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/) · [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

## Page packages

| | Default product page | Custom page 1 · Grocery budget | Custom page 2 · Pantry inventory |
|---|---|---|---|
| First question to answer | What do I need for this shop and dinner? | Which pack covers my need for less money? | What food do I have and how do I keep it current? |
| Proposed English searches | grocery list, family meal planner | grocery budget, grocery calculator, grocery list with prices | pantry inventory, fridge inventory, freezer inventory |
| Proposed US Spanish searches | lista de compras, lista del súper | lista de compras con precios, presupuesto de compras | inventario de despensa, inventario del congelador |
| First screenshot | Populated in-store list with items picked and still needed | Two packs compared for the same need, with the actual totals visible | Populated Pantry with three familiar foods and clear amounts |
| Next four screenshots | Dinner with lunch set aside, whole-pack comparison, receipt review into Pantry, then a distinct shortage or pickup correction | Pack sizes and shopper-entered prices, planned shop against the budget, a visible price or quantity change, then the resulting estimate | Receipt screenshot review, a corrected received amount, confirmed putaway, then a later quantity update or a meal using available stock |
| English promotional copy | Use the primary listing’s promotional text. | See which pack costs less for the amount you need. Compare your own prices, then check how the groceries fit your pickup budget. | Start with three foods you already have. Review a grocery receipt, save what came home and update what’s left as you cook. |
| Spanish promotional copy | Use the Spanish listing’s promotional text. | Compara paquetes según la cantidad que necesitas. Usa los precios de tu tienda y revisa cuánto queda de tu presupuesto. | Empieza con tres alimentos que ya tienes. Revisa un recibo, guarda lo que llegó a casa y actualiza lo que queda al cocinar. |
| Evidence of a good match | A new shopper can create a grocery list and recognize its dinner connection. | A shopper can explain why two packs at $2.70 cover the example need for $5.40. | A shopper can save three foods, change one amount and find it again after relaunch. |

Search phrases above describe the intended audience. Inspect the eligible keyword choices in App Store Connect for each localization after approval. Give the budget and pantry pages distinct selections. Preserve the broad default listing. Apple ties organic custom page routing to keywords from the latest approved version. A custom page must be approved and visible in search. Collecting screenshots, drafting copy or choosing a proposed phrase here changes nothing in the store. [Apple configuration and approval](https://developer.apple.com/help/app-store-connect/create-custom-product-pages/configure-multiple-product-page-versions/)

## Where to expand

**Mexico is the next market to evaluate.** The archive’s 50 Spanish observations cover US iPhone searches. Before enabling Mexico, research Mexican search results, verify grocery input, estimates, receipts and saved history in MXN, and test the subscription’s local offer and support with Mexican shoppers. The current [pickup money formatter](../ios/Features/Pickup/PickupModel.swift) explicitly uses USD. The [storage reference](FOODKEEPER-REFERENCE.md) documents US USDA guidance. Review regional suitability and consumer-facing copy before enabling a new storefront. Canada would need its own demand evidence, CAD checks and localization decision.

Set country availability for the app and the subscription separately when the owner authorizes launch. Use one app record as countries are added. A country-specific second binary or dozens of speculative pages would add maintenance without proving a shopper benefit. [App availability](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-for-your-app-on-the-app-store/) · [Subscription availability](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-availability-for-an-auto-renewable-subscription/)

## Measurement

Record each page's version, language, date range and acquisition source. Review first-time downloads and conversion in App Store Connect with the associated exposure. Compare shopper comprehension and completion of the promised task separately. Organic and campaign traffic can differ. A stronger conversion rate on a tightly targeted page does not establish that the app ranked higher for the query. Review the results before investing in a fourth page. [ASO evidence and source trails](ASO-RESEARCH-APPLICATION.md) · [Apple search and measurement](https://developer.apple.com/app-store/search/)
