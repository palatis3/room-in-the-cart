# Future arrival and current food boundary

A future-dated receipt or usable confirmation could cover today's protected portions, authorize physical carryover, and retire a still-pending offer. Foundation 2.1 S08 requires actual arrival and keeps later deliveries pending until confirmed in time.

New writes now reject future evidence against the injected clock. Live food allocation, carryover, stock-review freshness and offer/reminder projections use explicit current instants. Imported history is preserved; decoding remains timeless, exact replays stay valid, and an older superseded count is not revived. The native arrival picker is bounded to the present. Its new warning is localized in English and Spanish.

## Verified model behavior

The identical five new regression tests fail on original production head1080fad, at the intended temporal assertions. Root reviewed the failure locations; native65 and strict1 are retained. With the reviewed production fix and single-instant projection delta, all129 tests across14 affected classes pass, native0/strict0. Every selected case ran once; there are no skips or XCTest runtime warnings. The test source is byte-identical between negative and positive builds. Build-warning lines are retained separately and are not represented as zero compiler warnings.

Coverage includes rejected-write atomicity, exact boundary acceptance, SQLite reopen and retained history, protected portions, future receipt/latest correction/freezer exclusion, cook/fallback parity, stale stock review after time advances without a revision, physical carryover rejection, and offer/reminder route authorization before and at actual arrival. Money and original history remain unchanged.

Local execution used Xcode27.1 and an iPhone17Pro arm64 simulator on iOS26.2/23C54. Native case allowances remain720/900 seconds. Both owned model simulators were deleted. Original results, source snapshots and compiled products remain under the private scratch validation folder; copied inspection receipts and hashes bind this report to them.

## Limits

This is local model/persistence validation. Native arrival date-control interaction, the ordinary arrival UI journey, minimum-OS execution, physical notifications and release acceptance remain separate. No UI-only scratch harness or diagnostic overlay is installed by this change. Current hosted CI targets1080fad and cannot validate this later local fix.
