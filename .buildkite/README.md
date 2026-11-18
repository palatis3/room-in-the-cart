# On-demand iPhone tests

Install [pipeline.yml](pipeline.yml) as static steps in the Buildkite pipeline editor. Select the repository’s `codex/buildkite-native-qualification` branch for the trial, or `main` after integration. Disable automatic branch, pull request and fork builds for this pipeline. Each manual build uses one hosted `macos-27-medium` agent with Xcode 27.1 and the iOS 27.0 runtime. The shared concurrency limit allows two independent builds.

In **New Build**, select the pipeline branch and set these variables in **Options → Environment Variables**.

| Variable | Value |
| --- | --- |
| `RITC_CANDIDATE_BRANCH` | First-party branch containing the feature and its test |
| `RITC_CANDIDATE_SHA` | Full lowercase commit SHA at that branch’s tip |
| `RITC_TEST_ID` | One method from the ordinary Debug app or UI test target, using `Target/Suite/testMethod` |
| `RITC_TEST_IDS` | Alternative to `RITC_TEST_ID`. A space-separated list of up to eight distinct methods from either target |
| `RITC_TEST_COUNT` | Required with `RITC_TEST_IDS`. The number of methods in the list |

For one native UI journey, set `RITC_TEST_ID=RoomInTheCartUITests/RoomInTheCartUITests/testKnownComparisonSavesAndReopensWithItemOnlyLimit`. For a group, enter each environment variable on its own line as shown below.

```text
RITC_TEST_IDS=RoomInTheCartTests/ContextualNavigationTests/testInboxRequiresAssignedShopperAndAllPreviewCapabilities RoomInTheCartTests/ContextualNavigationTests/testOpenDestinationCannotFollowAnotherAccountHouseholdMemberShopOrRole
RITC_TEST_COUNT=2
```

Use methods compiled by the standard Debug scheme. Dedicated fixture profiles and live-permission tests use their own build configuration.

The job fetches the named branch from the public GitHub repository and checks its commit before compiling the Debug app. It compiles once, runs the selected methods serially on an iPhone 17 simulator, and checks the exact identities and count in the execution log and result bundle. Artifacts include the revision, selector manifest, summary, timing and log. The pipeline needs no signing identity, household credentials or deployment secrets.
