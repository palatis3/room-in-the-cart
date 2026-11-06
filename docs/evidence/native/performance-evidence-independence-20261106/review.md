# Performance evidence independence review

Approved for the bounded two-file scope; no actionable findings.

- Independently ran `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p test_check_ios_performance.py -v`: all 10 tests passed.
- AST comparison against HEAD confirms every non-main helper remains unchanged, including required metric/sample/unit checks, attachment origin and checked-row identity validation, read-only SQLite integrity/digest/fixture readback, baseline values, and exact environment/limit comparison.
- Scroll readback now runs after measurement validation fails. Its own failures remain recorded and fatal. Any measurement/readback error prevents calibration and baseline acceptance; the independent sidecar explicitly states releaseAcceptance=false.
- Rendered readback is skipped unless the complete attachment validator returns successfully, preserving authority for checked and unchecked row identities.
- Previously generated calibration and sidecar output is removed before evidence loading; failed current evidence cannot retain a prior successful calibration.
- Existing launch calibration, unavailable baseline, approved baseline, and regression outcomes remain covered and pass.

Scope: code and pure-Python synthetic tests only. No native execution, hosted mutation, or Apple metric availability claim. This preserves independent persistence evidence; it does not repair the missing XCTest metric.
