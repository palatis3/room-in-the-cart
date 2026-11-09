# Clarification contrast qualification: partial result

The isolated style correction passes English Large in light and dark appearances.
Privacy guidance and empty Question contrast measure7.083026:1 in light and
8.295239:1 in dark, above the unchanged4.5:1 threshold. Full screenshots were
reviewed for complete wording and visible targets at their respective scroll
positions. The original Cancel-preview regression also passes.

The largest-text case fails before opening clarification. Its original screenshot
and accessibility hierarchy show the fixture diagnostics occupying the upper509pt,
a four-page request list at0%, and no materialized target request row. The test
waited without scrolling. This supports a bounded test-navigation correction; it
does not establish an app contrast or large-text layout result. Dark AX5 was not
run after this shared navigation failure. No unchanged retry was made.

The fixture explicitly mirrors the ordinary app's appearance preference; these
passes do not qualify system-following appearance propagation. Style/test/fixture
changes remain isolated, pending largest-text qualification and integration.

## Exact execution

Source manifest: `14215009e8ce6d6af649d1c859801eb981971d8321f492fd095d3488c39e8894`.
Xcode27.1, iPhone17, iOS27.0 runtime24A434. Full contributor compilation passed
in24.194seconds with no Swift compiler warnings. Same source/products for all cases.

| Case | Native / strict exit | Whole-run seconds | Original run receipt SHA-256 |
| --- | --- | --- | --- |
| light-large | 0 / 0 | 74.538 | `0f7d103b35c7393e0ac192ccaa9406eb98bd9cdc1132bd06272463d57f906a5d` |
| dark-large | 0 / 0 | 85.575 | `d7c23f099758787bed45c4a674398428c2105f10a00fe1e7122fe0be4c076468` |
| light-ax5 | 65 / 1 | 54.356 | `653615cc94d9d6c831089cbbd0037967cf25702d5dd850c4cbd4cb3769cb34d5` |
| cancel-original | 0 / 0 | 145.932 | `74f584ea2a51120555d815ef26dfd67fe5b2d2395563cee9b990e6e4f213d3f2` |

Original results, logs, attachment exports, one-time inspections and visual review:
`.build/ClarificationContrastNov09/positive-r2/`. All four results are terminal;
source and products remained unchanged, and light/Large simulator traits restored.
Archive custody verifies561source and376product files plus executable modes in
`.build/NativeQualificationArchivesNov09/14215009e8ce6d6af649d1c859801eb981971d8321f492fd095d3488c39e8894/`.
Raw originals are preserved locally; this report is not a remote evidence backup.

The source predates the separate installed CoreDomain tombstone fix. Never copy
its older CoreDomain files back during clarification integration. Final combined
CI must cover both fixes at one immutable commit.
