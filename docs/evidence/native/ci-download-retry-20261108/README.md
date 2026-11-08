# Bounded workflow-linter download retry

The a305065 source-checks job stopped before checksum verification or linting because the pinned actionlint release download returned HTTP 504. The original failure remains recorded; no test assertion or security check failed at this step.

The local follow-up adds `--retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 30` to that single download. The pinned URL, version, SHA-256 verification, archive extraction and full workflow lint remain unchanged. Curl retries its documented transient responses, including 504, with exponential backoff. It does not retry every possible error. The 90-second limit governs starting retries; an already-started attempt can run up to its 30-second limit. There is no test, build or workflow retry in this change.

Validation used the actual workflow curl argument list against a loopback HTTP fixture, replacing only URL and output path:

- One 504 followed by success: two attempts, exit0, exact payload with no error-body residue.
- Permanent404: one attempt, exit22.
- Persistent503: four attempts, exit22 after approximately7seconds.
- Pinned actionlint1.7.12 and the repository workflow checker passed; all15 native queue nodes validated.

The first local lint invocation selected an environment without PyYAML and stopped at import. Using the existing PyYAML6.0.3 environment completed the unchanged checker. This is local validation, not hosted recovery. The a305065 workflow cohort continues without a replacement push. A separate CodeQL download also returned504 after its existing retries; this change does not alter CodeQL.

Original hosted excerpts remain privately in `.build/CIA305065Nov08/`; `hosted-failure.json` links the exact job and retained excerpt hash.
