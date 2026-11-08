# Safari foreground privacy: original failure and fixed result

The original product exposed an own request, unsent draft and private controls after Home→Safari while fresh authority was still pending. The locally committed correction conceals that view until current authority is established. Both same-actor and revoked-actor cases now pass the unchanged real Simulator Safari qualification.

| Case | Original held authorization | Fixed held authorization | Fixed final result |
| --- | --- | --- | --- |
| Same actor | Private request/draft/controls exposed; verifier fails | Loading only, private fields/controls concealed | Exact draft and own request restored |
| Revoked actor | Same exposure while revoked response held; verifier fails | Loading only, private fields/controls concealed | Exact access-ended notice, enabled Refresh, private content absent |

[Original baseline](baseline/README.md) remains byte-identical. [Fixed proof](fixed/README.md) retains exact receipts, native observations, build identity and independent offline verification. Both versions used the same fixture/probe/verifier behavior, actual Home→Safari without Reload/Back, unchanged document identity, one held authority request and zero product mutations. The change is the pinned product bundle, not relaxed privacy criteria.

Original source:975cfb15ccc402b55d31960f6d03d46c66104d69; fixed local source:58419f9822b26a93820c2f4cfa4a45e7cd257a11. Fixed source is **not deployed**. Separate validation records show original portable controls3pass/9fail, installed web tests152/152pass and Chromium14/14pass. The initial missing-Chrome attempt remains separately retained. Unit/source tests and Chromium are not substitutes for these two actual Safari cases.

Root's native observations and screenshots are in the CUA transcript; no standalone screenshot exports are claimed. This is Simulator Safari with synthetic household/API data. It does not establish physical-device, provider, App Switcher, continuous-frame or broader Safari acceptance. Runtime identity is retained exactly, including unresolved23C52/23C54 inventory duplication. All fixed listeners were reported stopped with ports closed; publication performed offline verification only.
