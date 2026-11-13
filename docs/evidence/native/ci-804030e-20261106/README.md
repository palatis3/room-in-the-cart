# Candidate804030e · live collection

Candidate `804030e68473d022e72b464940061c01c611a0bd` was published once to the existing draft PR. Six ordinary pull-request workflows started at attempt1, with no manual dispatch or retries. Changes add the reviewed five-slot macOS scheduler, paired strict workflow validation, independent performance/persisted-pickup evidence, and documentation. Native app/test bodies, cases, runtime pins and acceptance limits remain unchanged.

| Workflow | Run |
|---|---:|
| Core | 42272379454 |
| Deep | 42272379472 |
| Fixtures | 42272379477 |
| Performance | 42272379490 |
| Native wire | 42272379461 |
| Security | 42272379767 |

Security is independently verified: dependency review passed, JavaScript/TypeScript87rules andActions17rules report zero findings for exact merge `62b6dced75daffbe4d264a4312b71b0ad811112d`. Its parent and tree match the published candidate. Swift analysis is separately verified:27rules/0findings across all254runtime inputs, with11compiler diagnostics and292unresolved AST nodes retained. [Swift proof](swift-security.json). [Proof](security.json).

The first live concurrency snapshot shows one admitted job in each of the five shared slots and other jobs pending in those queues; this is admission evidence, not a full-run utilization or provider-availability claim. [Snapshot](initial-slot-summary.json) · [Publication](publication.json).

Native work is collecting. No combined acceptance is claimed. The original8f failures and terminal toolchain qualification remain preserved. Root owns decisions/security; ci_core_resume collects core/deep/performance read-only (session43785), and ci_fixtures_resume collects fixtures/native wire read-only (session34355). Detailed live state is `.build/CIResearch20261106/candidate-804030e/`; the current pointer is mirrored under the November5 andNovember6 research roots. Do not restart an active run on a polling timeout or reinterpret slot waiting as provider failure.
