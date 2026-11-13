# Bounded observation evidence postprocessing

Hosted [42732878538](https://github.com/palatis3/room-in-the-cart/actions/runs/42732878538) failed collector readiness before GO. Two later evidence-processing defects obscured its diagnostics: product verification applied the source ceiling, and copied XCTest diagnostic logs were mistaken for command output.

The correction retains separate ceilings: source 128 MiB, products/results 512 MiB, other phase artifacts 256 MiB, trace 128 MiB, attachments 64 MiB. Only descendants of exact real root evidence directories bypass command-log limits. Ordinary nested logs retain their limits; regular files and symlinks cannot masquerade as evidence containers. Exact path, byte, mode, aggregate, wall, disk and process-ownership checks remain enforced.

Independent review caught three overly broad admissions in the first proposed patch and added five controls. All 174 offline observer controls pass on the integrated successor. [Verification](verification.json) pins reviewed patches and retained results. No native run was repeated, no deadline changed, and no required metric or trace is qualified by this correction. The original interrupted result lacks Info.plist and remains failed.
