# UI09 hosted observer r3

All eight original XCTest cases passed, and the native process and strict checker both exited 0. The previously timed-out free contextual routes case passed in 188.42 seconds. The test export recorded zero runtime warnings across eight cases. The checker observed zero animation-idle messages and zero runner restarts in 4,331 console lines. The XCTest summary had no runtime-warning field. [Run 42497538157](https://github.com/palatis3/room-in-the-cart/actions/runs/42497538157)

The job failed its observer requirement. The collector started at 16:07:11.743 UTC and stopped at 16:07:17.019 after its first process-list query exceeded the two-second subprocess deadline. It completed zero polls and captured no target PID or probe. XCTest started 8.579 seconds after the collector stopped. The optional appearance query also timed out, leaving the appearance unknown and allowing the test to proceed.

This instrumented pass did not reproduce the original UI09 timeout. The capture remains unavailable, so the original cause remains open. An offline collector test can reproduce the initial process-list timeout and check that bounded recovery records the observation gap while preserving the capture completeness gate.

[Evidence](evidence.json) pins candidate `2397704ca4392281d396c152b40e350b60c0183e`, the run and job, the reported artifact digest, and CRC-32 and SHA-256 for six original members. Those members were retained byte for byte from 32,451 ZIP range bytes. The package contains no full archive, media, or result bundle.
