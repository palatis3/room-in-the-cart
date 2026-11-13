# Compact shared-meal picker locale — November 9, 2026

The Spanish fixture still shows `Nov 9, 2026` in its compact date control while
the expanded calendar shows `Noviembre de 2026`. The same earlier build reproduced
this on the original simulator and a dedicated simulator under both English and
confirmed Spanish system preferences. The dedicated device is now shut down.

One new isolated build compared the unchanged picker with explicit forwarding of
its inherited locale. Both diagnostic selectors passed native and strict checks;
root reviewed both compact screenshots. Both retain the English compact date.
SwiftUI locale and the enclosing SwiftUI calendar locale are `es_US`; the latter
calendar is Gregorian with America/New_York time zone. The existing picker still
receives its unchanged GMT time-zone modifier. These observations do not establish
the picker’s internal framework state or a calendar defect.

Locale forwarding did not repair the observation and is not installed in canonical
app source. No hardcoded locale, replacement control, calendar mutation or suppressed
assertion was adopted. Normal CI inventory is unchanged; localization acceptance
remains open. Preserved prior source/products allow reuse without another unchanged
control. [Exact diagnostic inputs and retained-original hashes](verification.json).
