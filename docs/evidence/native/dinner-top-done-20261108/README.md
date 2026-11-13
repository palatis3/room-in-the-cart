# Dinner keyboard Done: touch repair and visual qualification

The original bottom keyboard inset stalled the English dinner journey. Native
navigation-bar variants dismissed from center but failed tested edges. The next
candidate gives the focused Done action an owned rectangular target above the
form, keeping Cancel and committing reviewed details separate. The full original
journey retains unknown-quantity rejection, supply review, approval and relaunch.

The installed repair passes all five symmetric touch samples and the full
English journey, native and strict checks, with zero animation-idle misses.
It uses the owned sibling row with a native inline supply title. Root/helper
reviewed all ten screenshots and five after-action records: titles are visible,
actions remain separate, values persist, and Done disappears with the keyboard.
Two earlier behavior-passing candidates were rejected by visual review because
their supply title disappeared while a field was focused.

| Candidate | Build | Original English journey | Visual outcome |
| --- | --- | --- | --- |
| Top sibling row | Native/bundle pass | Native0, strict0, zero idle misses | Supply title absent |
| Same row, background respecting safe area | Native/bundle pass | Native0, strict0, zero idle misses | Supply title still absent |
| Top safe-area inset on Form | Native/bundle pass | Native65, strict1, zero idle misses | Review warning missing; supply not reached |
| Sibling row with explicit inline supply title | Native/bundle pass | Native0, strict0, zero idle misses | Titles visible; ten screenshots reviewed |

The second version tests the background-only explanation. SwiftUI's shape-style
background [defaults to ignoring safe-area edges](https://developer.apple.com/documentation/swiftui/view/background(_:ignoressafeareaedges:)).
Changing only that setting confines the visible background but does not restore
the title; the initial overpaint explanation is insufficient. The screenshots
and receipts here preserve that rejection rather than promoting a green test.

The rejected top-inset candidate puts the same control into a top safe-area inset on
each Form. It keeps the Form as primary navigation content, retains the same
button, padding, action and tests, and changes the surrounding layout relationship.
Its build passed, but the original English journey failed after tapping Review:
the unknown-quantity warning was not found, and the retained final screenshot
shows the editable draft. The first cleared-amount Done interaction passed; later
interactions and supply titles were not reached. This does not establish whether
the Review action was invoked. Native65/strict1/zero idle misses are retained.
Do not repeat that unchanged candidate or count its title hypothesis as verified.
A visible title and the original behavior are both required. The final candidate
returns to the sibling row and changes only the supply title's display mode to
native inline. It is a supported presentation choice, not proof of the underlying
framework cause. This three-file product/test repair is now installed locally;
All 261 Python checks, including 20 app-configuration tests, and generated-project
validation pass. The original Spanish largest-text case failed to locate Accept
idea: terminal native65/strict1, zero idle misses. The testcase took193.448s;
the full command took800.080585s including verbose failure diagnostics. The
result was inspected once, and the settings receipt confirms Large restoration.
The retained failure screen shows large-text supply review content, without
Accept in the viewport; it does not prove the control is absent or a scroll
boundary was reached. That scope is unqualified; see
[CURRENT-HANDOFF](../../../CURRENT-HANDOFF.md) for the next investigation. Minimum OS, Release and combined hosted checks remain open.

Original sources, products and complete results are retained under `.build/` in
`DinnerTopDoneNov08`, `DinnerTopDoneSafeAreaNov08`, `DinnerTopInsetNov08` and
`DinnerInlineTitleNov08`.
Each reuse preserves the prior source and compiled products with verified APFS
clones. The source manifest includes the current billing recovery. The same
owned iPhone17Pro/iOS26.2, Large text, light appearance and unchanged 720/900
second test allowances are used. No unchanged retry or weaker gate occurred.

The coordinate samples test the center and four interior edge midpoints of a
44-point region, each during an existing distinct editing interaction. They are
not an exhaustive physical touch or accessibility audit. Spanish, large Dynamic
Type, minimum OS, Release and full integration/release checks remain separate.
