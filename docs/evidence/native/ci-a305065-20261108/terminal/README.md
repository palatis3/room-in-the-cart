# Hosted CI for a305065

All six workflows for PR 1 head `a30506596ad3a0103396fccb29800c629c92bc30` were terminal at 13:00:41 UTC on November 8, 2026. Three workflows passed and three failed. The 52 listed jobs include 47 successes, four underlying failures, and the derivative Core gate failure.

| Workflow | Result | Hosted evidence |
| --- | --- | --- |
| Build and test | Failed | All 702 models passed. Ordinary UI passed 67 of 68 cases. Source checks and UI09 failed. [Run](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092731) |
| iOS fixture checks | Failed | All 69 native cases passed. The strict gate accepted 64 cases. The cook shard's five passes had unavailable runtime-warning evidence. [Run](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092696) |
| iOS deep checks | Passed | StoreKit passed 15 cases per locale. Each sanitizer job passed 437 cases and skipped three separately covered native-wire cases. [Run](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092699) |
| iOS Release performance | Passed | Launch, scroll, and rendered simulator baselines passed. Scroll hitch samples were unavailable. [Run](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092792) |
| Native Swift HTTPS and PostgreSQL | Passed | Six Node integration cases and ten exact XCTest scenarios passed. [Run](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092697) |
| Security checks | Failed | Actions CodeQL failed during its tool download. JavaScript and TypeScript CodeQL and dependency review passed. [Run](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092689) |

- The actionlint download returned HTTP 504 before checksum verification and workflow linting. [Source checks](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092731/job/128701759248)
- The Actions CodeQL bundle download returned HTTP 504 during the streaming attempt and three fallback attempts. Analysis did not start. [Actions CodeQL](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092689/job/128701758818)
- UI09's free contextual routes case timed out at 720 seconds. Its first animation-idle miss followed Done on the Store field. The checker attributed ten messages to the case, observed one further message after timeout, and recorded one runner restart. The test export recorded zero runtime warnings across the eight cases. [UI09](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092731/job/128717768488)
- The cook warning activity belonged to the fourth passing case and lacked its required issue-description attachment. Five separate unified-log Hang Risk records fell in the readback window. The strict warning count remains unavailable. [Cook fixture](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092696/job/128721455532)

The Core gate reported the source-check and iOS-test prerequisite failures. [Core gate](https://github.com/palatis3/room-in-the-cart/actions/runs/42471092731/job/128732720503)

[Terminal summary](terminal-summary.json) records source, run, job, and artifact hashes. [Fixture inventory](fixture-inventory.json) retains the 17 shards and 69 exact selectors. [Job log excerpts](job-log-excerpts.txt) preserve original line numbers. The package contains receipts and selected excerpts. Performance metrics are simulator evidence, and persisted pickup counts come from hosted SQLite readback receipts.
