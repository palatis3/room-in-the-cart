# On-demand iPhone test

Install [pipeline.yml](pipeline.yml) as static steps in the Buildkite pipeline editor. Select the repository’s `codex/buildkite-native-qualification` branch for the trial, or `main` after integration. Disable automatic branch, pull request and fork builds for this pipeline. Each manual build uses one hosted `macos-27-medium` agent with Xcode 27.1 and the iOS 27.0 runtime. The shared concurrency limit allows two independent builds.

In **New Build**, select the pipeline branch and set these variables in **Options → Environment Variables**.

| Variable | Value |
| --- | --- |
| `RITC_CANDIDATE_BRANCH` | First-party branch containing the feature and its test |
| `RITC_CANDIDATE_SHA` | Full lowercase commit SHA at that branch’s tip |
| `RITC_TEST_ID` | One method, for example `RoomInTheCartTests/ContextualNavigationTests/testInboxRequiresAssignedShopperAndAllPreviewCapabilities` |

The job fetches the named branch from the public GitHub repository and checks its commit before compiling the Debug app. It runs the selected test on an iPhone 17 simulator, validates the XCTest result against the exact selector, and publishes the revision, test summary, timing and execution log. The pipeline needs no signing identity, household credentials or deployment secrets.
