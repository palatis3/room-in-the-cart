# FoodKeeper storage reference

The offline guide uses FSIS FoodKeeper version 128. People choose a specific food, storage location and condition. The guide retains the source’s storage periods, non-numeric instructions and preparation-specific notes. All search and date review happen on the device. In Settings, open Help and then Food storage guide. Search accepts English and Spanish names in either interface language. Someone searching for “dry lentils” can choose “lentils” to see the official “Lentils, dried” entry. The person selects the food and variant before reviewing any dates.

## Provenance

The Food Safety and Inspection Service publishes dataset `usda-fsis-006`. The catalog lists CC0 1.0 for the dataset and for each English and Spanish JSON distribution. Both files identify workbook `FMA-Data-v128.xlsx`. Both mark version 128 current, with a source modification date displayed as `09-06-2018`. The separate catalog modification date is January 22, 2025. The publisher describes FoodKeeper’s purpose as freshness and quality. [Federal catalog](https://catalog.data.gov/dataset/fsis-foodkeeper-data) · [CC0 dedication](https://creativecommons.org/publicdomain/zero/1.0/) · [FoodKeeper program](https://www.foodsafety.gov/keep-food-safe/foodkeeper-app)

The following SHA-256 hashes identify the exact UTF-8 JSON texts used on November 17, 2026. The directly cataloged FSIS URLs returned 403 to the local client. Cached successful responses from those same official URLs supplied the source JSON. The published FoodSafety.gov app script references the other two resources. A separate fetch with a zero cache age returned HTTP 200 for each app resource. The compiler checks that each product name, variant, category ID and displayed value used in the guide agrees across the two publisher representations in its language.

| Input | SHA-256 |
| --- | --- |
| [FSIS English](https://www.fsis.usda.gov/shared/data/EN/foodkeeper.json) | `037df0d301126acd8a48824506f04d49d8be1a1144b81fa69e4170228dc2e91a` |
| [FSIS Spanish](https://www.fsis.usda.gov/shared/data/ES/foodkeeper.json) | `2a25209edc1d578f1f0002a0a896c54c26611a4d986c46ebcdc156554190687b` |
| [FoodSafety.gov English](https://www.foodsafety.gov/sites/default/files/foodkeeper_data_url_en.json) | `5fe0c3cf7d4e5ced69325b519ae92e8b9b21dfe33d88b6fe2bb4e8dc52ed4192` |
| [FoodSafety.gov Spanish](https://www.foodsafety.gov/sites/default/files/foodkeeper_data_url_es.json) | `d1f0bf4f28395c9f3c86f119685ffacfc79c3d97c6bf395bead203e62a9ce2c8` |

## Coverage and date handling

English contains 661 product IDs and Spanish contains 662. The guide includes 654 distinctly identifiable bilingual variants and 1,288 displayed periods or source instructions, including 1,163 numeric ranges. It also preserves 183 bilingual sets of contextual notes. Source rows with missing guidance, disagreement or ambiguous identity stay out of the corresponding calculation. Spanish-only ID 221 has no English match. ID 645 has different category IDs, and IDs 264 and 496 share an indistinguishable Spanish name and category.

The reference distinguishes ordinary storage, storage since purchase, after opening and after thawing. Date calculations require a numeric, anchored rule and confirmation of the date, uninterrupted storage and package instructions. Notes, conflicting fields, package-date qualifiers, unanchored rules and hour-based guidance limit where a date range can be offered. 337 products have at least one eligible condition. Calendar addition retains the start day’s time zone. A lot’s recount, freezer move, planned consumption or receipt scan supplies no implicit starting date.

For example, ID 142 gives a 3–4 day refrigerated range after opening for canned chicken in both languages. It has no generic refrigerator or after-thawing interval. ID 179 points to the package use-by date for general refrigeration. Its separate after-opening instruction remains readable, while its package instruction keeps automatic dates disabled.

## Reproduction

Place the four exact response bodies in a directory as `en.json`, `es.json`, `web-en.json` and `web-es.json`. Run `python3 scripts/build_foodkeeper_reference.py DIRECTORY --check` to verify the pinned inputs and deterministic bundled output. Use the command without `--check` to generate that output.

A reminder integration can persist the explicit FoodKeeper version, product ID, condition, civil start day and zone with the customer’s reviewed choice. Recheck the current lot identity and revision, storage, opening evidence and authorization before a reminder is saved or presented. Moving, erasing or correcting a lot requires rechecking its range. A missing match or uncertain thaw history leaves the person’s manually selected reminder date available to the owning pantry workflow.
